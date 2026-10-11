#!/usr/bin/env bash
# Ships the current working tree to the production server, rebuilds the app
# image, runs migrations, and restarts the stack with zero manual steps.
# Usage: bin/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="nurseprep-prod"
REMOTE_DIR="/opt/nurseprep"

echo "==> Syncing source to $HOST:$REMOTE_DIR"
rsync -az --delete \
  --exclude='_build/' --exclude='deps/' --exclude='.git/' --exclude='tmp/' \
  --exclude='assets/node_modules/' --exclude='priv/static/assets/' \
  --exclude='.elixir_ls/' --exclude='cover/' --exclude='doc/' \
  --exclude='.env' --exclude='.env.*' --exclude='evolution/.env' \
  --exclude='backups/' \
  "$ROOT"/ "$HOST":"$REMOTE_DIR"/

echo "==> Building app image"
ssh "$HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml --env-file .env.prod build app"

echo "==> Running database migrations"
ssh "$HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml --env-file .env.prod run --rm app /app/bin/migrate"

echo "==> Restarting stack"
ssh "$HOST" "cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml --env-file .env.prod up -d"

echo "==> Waiting for health"
sleep 5
ssh "$HOST" "docker ps --filter 'name=nurseprep_' --format 'table {{.Names}}\t{{.Status}}'"

echo "==> Smoke test"
curl -sS -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" https://nurseprep.com.ng/ || {
  echo "Smoke test failed - check: ssh $HOST 'docker logs nurseprep_app --tail 100'" >&2
  exit 1
}

echo "Deploy complete."
