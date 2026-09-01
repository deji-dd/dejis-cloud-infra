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

# Dump all databases & roles, compress on the fly, and stream directly over SSH without storing locally
echo "==> Dumping full cluster (pg_dumpall) and streaming compressed backup over SSH..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "${CONTAINER_NAME}" pg_dumpall -U "${DB_USER}" | \
  gzip -c | \
  ssh -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "cat > ${GCP_DIR}/${BACKUP_FILENAME}"

echo "==> Backup stream completed successfully!"

# Retention cleanup: remove backups older than RETENTION_DAYS on the GCP instance (-n prevents consuming stdin)
if [ "${RETENTION_DAYS}" -gt 0 ]; then
  echo "==> Pruning backups older than ${RETENTION_DAYS} days on remote instance..."
  ssh -n -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" \
    "find ${GCP_DIR} \( -name 'pg_cluster_backup_*.sql.gz' -o -name 'db_backup_*.sql.gz' \) -type f -mtime +${RETENTION_DAYS} -delete"
fi

echo "==> All done: $(date +'%Y-%m-%d_%H-%M-%S')"
