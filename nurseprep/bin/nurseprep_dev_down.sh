#!/usr/bin/env bash
# Stops what nurseprep_dev_up.sh started: the managed `mix phx.server`
# process, then the Evolution API Docker stack (containers stopped, not
# removed-the paired WhatsApp session lives in the postgres/instances
# volumes and survives this).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVOLUTION_DIR="$ROOT/evolution"
PID_FILE="$ROOT/tmp/phx_server.pid"

if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "==> Stopping Phoenix server (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
else
  echo "==> No pid file at $PID_FILE-no managed Phoenix server to stop."
fi

if [ -d "$EVOLUTION_DIR" ]; then
  echo "==> Stopping Evolution API stack (volumes kept, pairing persists)"
  (cd "$EVOLUTION_DIR" && docker compose stop)
fi

echo "Stopped."
