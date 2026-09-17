#!/usr/bin/env bash

# PostgreSQL directory layout and backup script/cron
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Creating PostgreSQL persistent storage directory..."
PG_DATA_DIR="/var/lib/postgresql/data"
run mkdir -p "$PG_DATA_DIR"
run chmod 700 "$PG_DATA_DIR"
success "PostgreSQL storage directory prepared: $PG_DATA_DIR"

if [[ "${SKIP_BACKUP_CRON}" != "true" ]]; then
  log "Setting up automated PostgreSQL backup script and cron job..."
  BACKUP_DIR="/var/backups"
  BACKUP_SCRIPT="${BACKUP_DIR}/backup-postgres.sh"
  run mkdir -p "$BACKUP_DIR"
  run chmod 700 "$BACKUP_DIR"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would write backup script to $BACKUP_SCRIPT"
  else
    cat > "$BACKUP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/mnt/nvme/backups"
TIMESTAMP=$(date +'%Y-%m-%d_%H%M%S')
BACKUP_FILE="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
CONTAINER_NAME="stock-postgres"
DB_USER="${POSTGRES_USER:-stockuser}"
DB_NAME="${POSTGRES_DB:-stockdata}"

mkdir -p "$BACKUP_DIR"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"
  chmod 600 "$BACKUP_FILE"
  find "$BACKUP_DIR" -type f -name "db_*.sql.gz" -mtime +14 -delete
else
  echo "Container '${CONTAINER_NAME}' not running; skipping backup." >&2
fi
EOF
    chmod 750 "$BACKUP_SCRIPT"
    ln -sf "$BACKUP_SCRIPT" /usr/local/bin/backup-postgres
  fi

  CRON_BACKUP="/etc/cron.d/stock-ticker-backup"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would create cron job in $CRON_BACKUP"
  else
    cat > "$CRON_BACKUP" <<EOF
# Daily automated PostgreSQL backup at 03:00 AM
0 3 * * * root ${BACKUP_SCRIPT} >> /var/log/stock-ticker-backup.log 2>&1
EOF
    chmod 644 "$CRON_BACKUP"
  fi
  success "Automated PostgreSQL backup configured."
fi
