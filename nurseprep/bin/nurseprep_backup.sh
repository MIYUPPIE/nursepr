#!/usr/bin/env bash
# Daily Postgres backup for both databases in the prod stack (app + Evolution).
# Runs on the host via cron, dumps through the running containers, gzips,
# and prunes anything older than 7 days. Intended to be invoked as:
#   0 3 * * * /opt/nurseprep/bin/nurseprep_backup.sh >> /var/log/nurseprep_backup.log 2>&1
set -euo pipefail

BACKUP_DIR="/opt/nurseprep/backups"
RETENTION_DAYS=7
STAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "==> [$STAMP] Backing up nurseprep_app_db"
docker exec nurseprep_app_db pg_dump -U nurseprep nurseprep_prod | gzip > "$BACKUP_DIR/app_db_$STAMP.sql.gz"

echo "==> [$STAMP] Backing up nurseprep_evolution_postgres"
docker exec nurseprep_evolution_postgres pg_dump -U evolution evolution | gzip > "$BACKUP_DIR/evolution_db_$STAMP.sql.gz"

echo "==> Pruning backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+$RETENTION_DAYS" -delete

echo "==> Done. Current backups:"
ls -lh "$BACKUP_DIR"
