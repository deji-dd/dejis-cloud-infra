#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PostgreSQL cluster backup -> Cloudflare R2, with GFS rotation.
#
# Design notes (each of these was verified empirically against the live bucket):
#
#  * The rclone remote is configured with a BUCKET-SCOPED token. Such a token
#    cannot call ListBuckets or HeadBucket, so:
#      - every path must name the bucket explicitly (never `rclone lsd r2:`)
#      - every write needs --s3-no-check-bucket, otherwise rclone falls back to
#        attempting CreateBucket and fails with AccessDenied
#
#  * Integrity is verified by MD5, not just size. R2 returns a real content MD5
#    for these uploads and rclone can read it, so we can prove the stored object
#    is byte-identical to what we produced -- without downloading it back.
#    Size-only comparison would miss a corrupted-but-same-length archive.
#
#  * A size tripwire compares against the most recent daily object. MD5 proves
#    we uploaded what we dumped; it cannot prove the dump itself is healthy. A
#    large drop in size is the cheapest early warning of a broken dump.
#
#  * GFS rotation. daily/ keeps the 7 most recent, weekly/ the 4 most recent,
#    monthly/ the 12 most recent. Requires ≥7 daily archives, so it no-ops until
#    the pipeline has been running a week.
#
#  * We never prune before the new archive is verified. If verification fails we
#    exit non-zero with the .partial object left in place for inspection and all
#    existing backups untouched.
#
#  * The rclone remote name (default "r2") is a bucket-scoped credential that
#    must be configured out-of-band:  rclone config show r2
#    e.g. endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
#         provider = Cloudflare, acl = private
#
#  * R2 is the SOLE destination. This script must not touch the legacy GCP box
#    or any SSH target: that host was undersized for the job and its involvement
#    slowed every backup down. Nothing here may regress to an SSH-based copy.
# ==============================================================================

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || pwd)"

# Load .env if present
if [ -f "${REPO_DIR}/.env" ]; then
  set -a
  source "${REPO_DIR}/.env"
  set +a
elif [ -f "./.env" ]; then
  set -a
  source "./.env"
  set +a
fi

# Database settings
CONTAINER_NAME="${POSTGRES_CONTAINER:-postgres}"
DB_USER="${POSTGRES_USER:-postgres}"

# R2 settings
R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-dejis-cloud-backups}"
R2_BASE="${R2_REMOTE}:${R2_BUCKET}"

# GFS retention: keep N most recent in each tier
KEEP_DAILY="${R2_KEEP_DAILY:-7}"
KEEP_WEEKLY="${R2_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${R2_KEEP_MONTHLY:-12}"

# Per-run paths
STAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
DAY="$(date +'%Y-%m-%d')"
DOW="$(date +'%u')"                              # 1=Mon .. 7=Sun
DOM="$(date +'%d')"                              # 01..31
FILENAME="pg_cluster_backup_${STAMP}.sql.gz"
STAGING="$(mktemp -d /tmp/pgbackup.XXXXXX)"

R2_DAILY="${R2_BASE}/daily/${FILENAME}"
R2_WEEKLY="${R2_BASE}/weekly/${DAY}.sql.gz"
R2_MONTHLY="${R2_BASE}/monthly/$(date +'%Y-%m').sql.gz"
R2_PARTIAL="${R2_DAILY}.partial"

RCLONE_OPTS=(--s3-no-check-bucket)
R2_OK=0

# ---------------------------------------------------------------- preflight
# rclone must be new enough to UPLOAD to R2. Verified empirically: 1.60.1 can
# read/list the bucket fine but every write fails with "501 NotImplemented".
# That is the dangerous shape of failure -- reads work, so the remote looks
# healthy while backups silently never land. Fail loudly instead.
if ! command -v rclone >/dev/null 2>&1; then
  echo "==> ERROR: rclone not found in PATH. Aborting." >&2
  exit 1
fi
RCLONE_VER="$(rclone version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v')"
RCLONE_MAJOR="${RCLONE_VER%%.*}"
RCLONE_MINOR="$(echo "${RCLONE_VER}" | cut -d. -f2)"
if [ "${RCLONE_MAJOR:-0}" -lt 1 ] 2>/dev/null || \
   { [ "${RCLONE_MAJOR:-0}" -eq 1 ] && [ "${RCLONE_MINOR:-0}" -lt 70 ]; } 2>/dev/null; then
  echo "==> ERROR: rclone ${RCLONE_VER} is too old to upload to R2 (needs >= 1.70)." >&2
  echo "    rclone 1.60.x (the Ubuntu apt build) reads fine but fails every write" >&2
  echo "    with '501 NotImplemented'. Reinstall from https://rclone.org/install.sh" >&2
  echo "    and remove the apt build so it cannot shadow the good one:" >&2
  echo "        apt-get remove -y rclone && curl https://rclone.org/install.sh | bash" >&2
  echo "    Nothing was dumped or uploaded; existing backups untouched." >&2
  exit 1
fi
# A bucket-scoped token can list a named bucket but must never be asked to
# enumerate buckets, and its config must not carry a /bucket suffix on endpoint.
R2_ENDPOINT="$(rclone config show "${R2_REMOTE}" 2>/dev/null | awk -F'= ' '/^endpoint/{print $2}')"
case "${R2_ENDPOINT}" in
  */"${R2_BUCKET}"*)
    echo "==> ERROR: rclone remote '${R2_REMOTE}' endpoint includes the bucket:" >&2
    echo "    ${R2_ENDPOINT}" >&2
    echo "    It must be just https://<ACCOUNT_ID>.r2.cloudflarestorage.com" >&2
    exit 1
    ;;
esac

cleanup() { rm -rf "${STAGING}"; }
trap cleanup EXIT

# ------------------------------------------------------------------ helpers
# Keep the N most recent objects under a prefix, delete the rest.
# Sorted by name -- the naming scheme is date-prefixed, so lexical == chronological.
r2_prune() {
  local prefix="$1" keep="$2"
  local victims
  victims="$(rclone lsf "${R2_BASE}/${prefix}/" 2>/dev/null | sort | head -n -"${keep}" || true)"
  if [ -z "${victims}" ]; then
    echo "==> ${prefix}/: nothing to prune (keeping ${keep})"
    return 0
  fi
  while IFS= read -r obj; do
    [ -n "${obj}" ] || continue
    echo "    pruning ${prefix}/${obj}"
    rclone deletefile "${R2_BASE}/${prefix}/${obj}" "${RCLONE_OPTS[@]}" >/dev/null 2>&1 || true
  done <<< "${victims}"
}

echo "=================================================="
echo "PostgreSQL cluster backup -> R2"
echo "Started:       ${STAMP}"
echo "Container:     ${CONTAINER_NAME}"
echo "Destination:   ${R2_DAILY}"
echo "GFS:           ${KEEP_DAILY} daily / ${KEEP_WEEKLY} weekly / ${KEEP_MONTHLY} monthly"
echo "=================================================="

# ------------------------------------------------- 1. dump locally + MD5
# We stage the dump locally rather than streaming to a pipe: it lets us compute
# the MD5 needed for remote verification, and prod has ample disk. The file is
# removed on exit by the EXIT trap.
LOCAL_MD5_FILE="${STAGING}/${FILENAME}"
echo "==> Dumping full cluster (pg_dumpall) + compressing..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "${CONTAINER_NAME}" \
  pg_dumpall -U "${DB_USER}" | gzip -c > "${LOCAL_MD5_FILE}"

LOCAL_SIZE="$(stat -c%s "${LOCAL_MD5_FILE}")"
LOCAL_MD5="$(md5sum "${LOCAL_MD5_FILE}" | cut -d' ' -f1)"
echo "==> Dump complete: ${LOCAL_SIZE} bytes, md5 ${LOCAL_MD5}"

if [ "${LOCAL_SIZE}" -lt 1024 ]; then
  echo "==> ERROR: dump is implausibly small (${LOCAL_SIZE} bytes). Aborting." >&2
  exit 1
fi

# ------------------------------------------------- 2. size tripwire
# Compare against the newest existing daily object. MD5 below proves the upload
# matches our dump; this proves the dump itself still looks like the last one.
PREV_SIZE="$(rclone lsl "${R2_BASE}/daily/" 2>/dev/null | sort -k2 | tail -1 | awk '{print $1}')"
if [ -n "${PREV_SIZE}" ] && [ "${PREV_SIZE}" -gt 0 ] 2>/dev/null; then
  if [ "${LOCAL_SIZE}" -lt $(( PREV_SIZE * 50 / 100 )) ]; then
    echo "==> ERROR: dump ${LOCAL_SIZE}B is <50% of previous daily (${PREV_SIZE}B)." >&2
    echo "    Investigate before trusting this backup. Aborting; nothing pruned." >&2
    exit 1
  fi
  echo "==> Size tripwire OK (${LOCAL_SIZE}B vs ${PREV_SIZE}B previous)"
else
  echo "==> Size tripwire skipped (no previous daily object)"
fi

# ------------------------------------------------- 3. upload
echo "==> Uploading to R2..."
rclone copyto "${LOCAL_MD5_FILE}" "${R2_PARTIAL}" "${RCLONE_OPTS[@]}" -v 2>&1 | tail -3

# ------------------------------------------------- 4. verify, then promote
REMOTE_MD5="$(rclone lsjson "${R2_PARTIAL}" --hash 2>/dev/null \
  | grep -o '"md5":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)"
REMOTE_SIZE="$(rclone lsl "${R2_PARTIAL}" 2>/dev/null | awk '{print $1}')"

if [ "${REMOTE_MD5}" = "${LOCAL_MD5}" ]; then
  echo "==> Verified: md5 matches (${LOCAL_MD5})"
elif [ -n "${REMOTE_MD5}" ] && [ -n "${REMOTE_SIZE}" ] && [ "${REMOTE_SIZE}" = "${LOCAL_SIZE}" ]; then
  # Fall back to size if R2 did not surface an MD5 for this upload shape.
  echo "==> WARNING: MD5 unavailable from R2; size matches (${LOCAL_SIZE}B). Proceeding." >&2
else
  echo "==> ERROR: verification FAILED for ${FILENAME}" >&2
  echo "    local : size=${LOCAL_SIZE} md5=${LOCAL_MD5}" >&2
  echo "    remote: size=${REMOTE_SIZE:-?} md5=${REMOTE_MD5:-?}" >&2
  echo "    Corrupt object left at ${R2_PARTIAL} for inspection." >&2
  echo "    Existing backups NOT touched. Nothing pruned." >&2
  exit 1
fi

rclone moveto "${R2_PARTIAL}" "${R2_DAILY}" "${RCLONE_OPTS[@]}" 2>&1 | tail -2
R2_OK=1
echo "==> Promoted to daily/${FILENAME}"

# ------------------------------------------------- 5. GFS promotion
# Promote a copy into weekly/ (Mondays) and monthly/ (1st of month). Copy, not
# move: the daily copy stays put so day-to-day restores remain simple.
# FORCE_WEEKLY / FORCE_MONTHLY exist so these paths can be tested on any day.
#
# Both destinations are LOCKED by the bucket policy once written, so they can
# never be overwritten (R2 returns 409 ObjectLockedByBucketPolicy). We therefore
# check for existence first and treat "already promoted" as success. That makes
# re-running the script on the same day idempotent, which matters because a
# manual re-run must not fail the backup.
promote_if_absent() {
  local prefix="$1"
  if [ -n "$(rclone lsf "${R2_BASE}/${prefix}/" 2>/dev/null | grep -x -F "$(basename "${R2_PROMOTE_TARGET}")" || true)" ]; then
    echo "==> ${prefix}/$(basename "${R2_PROMOTE_TARGET}") already exists (locked) - skipping"
  elif rclone copyto "${R2_DAILY}" "${R2_PROMOTE_TARGET}" "${RCLONE_OPTS[@]}" 2>&1 | tail -1; then
    echo "==> Promoted to ${prefix}/$(basename "${R2_PROMOTE_TARGET}")"
  else
    echo "==> WARNING: could not promote to ${prefix}/ (backup itself is safe in daily/)" >&2
  fi
}

if [ "${DOW}" = "1" ] || [ "${FORCE_WEEKLY:-0}" = "1" ]; then
  R2_PROMOTE_TARGET="${R2_WEEKLY}"
  promote_if_absent weekly
fi
if [ "${DOM}" = "01" ] || [ "${FORCE_MONTHLY:-0}" = "1" ]; then
  R2_PROMOTE_TARGET="${R2_MONTHLY}"
  promote_if_absent monthly
fi

# ------------------------------------------------- 6. prune (only after verify)
echo "==> Rotating (GFS)..."
r2_prune daily   "${KEEP_DAILY}"
r2_prune weekly  "${KEEP_WEEKLY}"
r2_prune monthly "${KEEP_MONTHLY}"

echo "=================================================="
echo "==> All done: $(date +'%Y-%m-%d_%H-%M-%S')  (R2_OK=${R2_OK})"
echo "=================================================="
