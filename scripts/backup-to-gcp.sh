#!/usr/bin/env bash
set -euo pipefail

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

# GCP Remote Destination Settings
# GCP_BACKUP_HOST can be an IP, domain, or Tailscale / SSH alias (e.g. gcp)
GCP_USER="${GCP_BACKUP_USER:-root}"
GCP_HOST="${GCP_BACKUP_HOST:-gcp}"
GCP_DIR="${GCP_BACKUP_DIR:-/backups}"
RETENTION_DAYS="${GCP_BACKUP_RETENTION_DAYS:-14}"

TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_FILENAME="pg_cluster_backup_${TIMESTAMP}.sql.gz"

echo "=================================================="
echo "Starting PostgreSQL full cluster backup: ${TIMESTAMP}"
echo "Container: ${CONTAINER_NAME}"
echo "Remote destination: ${GCP_USER}@${GCP_HOST}:${GCP_DIR}/${BACKUP_FILENAME}"
echo "=================================================="

# Ensure remote backup directory exists (-n prevents consuming stdin)
ssh -n -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "mkdir -p ${GCP_DIR}"

# Dump all databases & roles, compress on the fly, and stream directly over SSH without storing locally.
# The stream lands in a .partial file first: if the transfer dies mid-way, `cat` still exits 0, so
# without this the script would report success and then prune good backups behind a corrupt one.
PARTIAL_FILENAME="${BACKUP_FILENAME}.partial"
REMOTE_PATH="${GCP_DIR}/${BACKUP_FILENAME}"
REMOTE_PARTIAL="${GCP_DIR}/${PARTIAL_FILENAME}"

echo "==> Dumping full cluster (pg_dumpall) and streaming compressed backup over SSH..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "${CONTAINER_NAME}" pg_dumpall -U "${DB_USER}" | \
  gzip -c | \
  ssh -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "cat > ${REMOTE_PARTIAL}"

echo "==> Stream finished. Verifying the archive is intact on the remote instance..."

# Verify BEFORE promoting and BEFORE pruning: gzip -t reads the whole stream and validates the CRC
# plus the ISIZE trailer, which catches a truncated transfer that the exit status cannot.
if ssh -n -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "gzip -t '${REMOTE_PARTIAL}'"; then
  ssh -n -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" \
    "mv '${REMOTE_PARTIAL}' '${REMOTE_PATH}'"
  echo "==> Verified OK. Promoted to ${BACKUP_FILENAME}"
else
  echo "==> ERROR: backup failed verification on the remote instance." >&2
  echo "    Corrupt archive left at ${REMOTE_PARTIAL} for inspection; its mtime is preserved so it" >&2
  echo "    will not be pruned until 2x RETENTION_DAYS. Existing backups were NOT touched." >&2
  exit 1
fi

# Retention cleanup: remove backups older than RETENTION_DAYS on the GCP instance (-n prevents consuming stdin)
if [ "${RETENTION_DAYS}" -gt 0 ]; then
  echo "==> Pruning backups older than ${RETENTION_DAYS} days on remote instance..."
  ssh -n -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" \
    "find ${GCP_DIR} \( -name 'pg_cluster_backup_*.sql.gz' -o -name 'db_backup_*.sql.gz' \) -type f -mtime +${RETENTION_DAYS} -delete; \
     find ${GCP_DIR} -name '*.sql.gz.partial' -type f -mtime +$((RETENTION_DAYS * 2)) -delete"
fi

echo "==> All done: $(date +'%Y-%m-%d_%H-%M-%S')"
