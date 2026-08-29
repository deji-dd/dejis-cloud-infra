#!/usr/bin/env bash
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [ -f "${REPO_DIR}/.env" ]; then
  # export variables from .env
  set -a
  source "${REPO_DIR}/.env"
  set +a
fi

# Database settings
CONTAINER_NAME="${POSTGRES_CONTAINER:-postgres}"
DB_NAME="${POSTGRES_DB:-dejis_cloud_db}"
DB_USER="${POSTGRES_USER:-postgres}"

# GCP Remote Destination Settings
# GCP_BACKUP_HOST can be an IP, domain, or Tailscale / SSH alias (e.g. gcp)
GCP_USER="${GCP_BACKUP_USER:-root}"
GCP_HOST="${GCP_BACKUP_HOST:-gcp}"
GCP_DIR="${GCP_BACKUP_DIR:-/backups}"
RETENTION_DAYS="${GCP_BACKUP_RETENTION_DAYS:-14}"

TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_FILENAME="db_backup_${DB_NAME}_${TIMESTAMP}.sql.gz"

echo "=================================================="
echo "Starting PostgreSQL backup: ${TIMESTAMP}"
echo "Target DB: ${DB_NAME} (container: ${CONTAINER_NAME})"
echo "Remote destination: ${GCP_USER}@${GCP_HOST}:${GCP_DIR}/${BACKUP_FILENAME}"
echo "=================================================="

# Ensure remote backup directory exists
ssh -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "mkdir -p ${GCP_DIR}"

# Dump database, compress on the fly, and stream directly over SSH without storing locally
echo "==> Dumping and streaming compressed backup over SSH..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "${CONTAINER_NAME}" pg_dump -U "${DB_USER}" "${DB_NAME}" | \
  gzip -c | \
  ssh -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" "cat > ${GCP_DIR}/${BACKUP_FILENAME}"

echo "==> Backup stream completed successfully!"

# Retention cleanup: remove backups older than RETENTION_DAYS on the GCP instance
if [ "${RETENTION_DAYS}" -gt 0 ]; then
  echo "==> Pruning backups older than ${RETENTION_DAYS} days on remote instance..."
  ssh -o StrictHostKeyChecking=no "${GCP_USER}@${GCP_HOST}" \
    "find ${GCP_DIR} -name 'db_backup_${DB_NAME}_*.sql.gz' -type f -mtime +${RETENTION_DAYS} -delete"
fi

echo "==> All done: $(date +'%Y-%m-%d_%H-%M-%S')"
