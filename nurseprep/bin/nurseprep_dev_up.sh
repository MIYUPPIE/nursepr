#!/usr/bin/env bash
# Starts the full local WhatsApp-testing stack: the Evolution API Docker
# stack (evolution/), then `mix phx.server` wired up with the env vars it
# needs to actually talk to that instance. Idempotent-safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVOLUTION_DIR="$ROOT/evolution"
RUN_DIR="$ROOT/tmp"
PID_FILE="$RUN_DIR/phx_server.pid"
LOG_FILE="$RUN_DIR/phx_server.log"
INSTANCE="nurseprep"

mkdir -p "$RUN_DIR"

if [ ! -f "$EVOLUTION_DIR/.env" ]; then
  echo "evolution/.env is missing. Run: cd evolution && cp .env.example .env, set AUTHENTICATION_API_KEY, then retry." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$EVOLUTION_DIR/.env"

# Root .env (Paystack, etc.) isn't loaded by anything else-no dotenv lib
# in the app, no direnv on this machine-so without this, keys dropped in
# there silently never reach the running server. `set -a` exports every
# var the sourced file defines, same as a plain KEY=value dotenv would.
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  echo "==> Loaded $ROOT/.env into the environment"
fi

echo "==> Starting Evolution API stack (docker compose)"
(cd "$EVOLUTION_DIR" && docker compose up -d)

echo "==> Waiting for Evolution API health check"
status="starting"
for _ in $(seq 1 30); do
  status=$(docker inspect --format='{{.State.Health.Status}}' nurseprep_evolution_api 2>/dev/null || echo "missing")
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "Evolution API never became healthy (status: $status). Check: docker logs nurseprep_evolution_api" >&2
  exit 1
fi
echo "    Evolution API healthy."

state=$(
  curl -s "http://localhost:8080/instance/connectionState/$INSTANCE" \
    -H "apikey: $AUTHENTICATION_API_KEY" |
    python3 -c "import json,sys; print(json.load(sys.stdin).get('instance',{}).get('state','unknown'))" 2>/dev/null ||
    echo "no-instance"
)
echo "    Instance '$INSTANCE' state: $state"
if [ "$state" != "open" ]; then
  cat <<EOF
    Not paired yet. To (re)pair:
      source evolution/.env
      curl -s http://localhost:8080/instance/connect/$INSTANCE -H "apikey: \$AUTHENTICATION_API_KEY" \\
        | python3 -c "import json,base64,sys; d=json.load(sys.stdin); open('/tmp/qr.png','wb').write(base64.b64decode(d['base64'].split(',',1)[1]))"
      xdg-open /tmp/qr.png
    Then scan from WhatsApp -> Settings -> Linked Devices -> Link a device.
EOF
fi

echo "==> Checking for an existing process on port 4000"
existing_pids="$(lsof -ti tcp:4000 2>/dev/null || true)"
tracked_pid=""
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  tracked_pid="$(cat "$PID_FILE")"
fi

if [ -n "$existing_pids" ]; then
  if [ -n "$tracked_pid" ] && echo "$existing_pids" | grep -qx "$tracked_pid"; then
    echo "    Phoenix server already running under our management (pid $tracked_pid). Leaving it alone."
    echo
    echo "nurseprep is up: http://localhost:4000  |  Evolution: http://localhost:8080 (state: $state)  |  logs: $LOG_FILE"
    exit 0
  else
    echo "    Port 4000 is held by an untracked process (pid(s): $existing_pids)-likely a manually-started"
    echo "    'mix phx.server' without the Evolution env vars. Stopping it so the managed one can bind."
    kill $existing_pids 2>/dev/null || true
    sleep 1
    kill -9 $existing_pids 2>/dev/null || true
  fi
fi

echo "==> Starting mix phx.server with Evolution env vars"
cd "$ROOT"
EVOLUTION_API_BASE_URL="http://localhost:8080" \
EVOLUTION_API_INSTANCE="$INSTANCE" \
EVOLUTION_API_KEY="$AUTHENTICATION_API_KEY" \
EVOLUTION_WEBHOOK_TOKEN="${NURSEPREP_WEBHOOK_TOKEN:-}" \
  nohup mix phx.server >"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"

echo "    Waiting for it to boot (pid $(cat "$PID_FILE"))..."
booted=false
for _ in $(seq 1 60); do
  if grep -q "Running NursePrepWeb.Endpoint" "$LOG_FILE" 2>/dev/null; then
    booted=true
    break
  fi
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Phoenix server exited during boot. Last 40 lines of $LOG_FILE:" >&2
    tail -40 "$LOG_FILE" >&2
    exit 1
  fi
  sleep 1
done

if [ "$booted" != "true" ]; then
  echo "Phoenix server didn't report ready within 60s-check $LOG_FILE" >&2
  exit 1
fi

echo
echo "nurseprep is up:"
echo "  App:        http://localhost:4000"
echo "  Evolution:  http://localhost:8080 (instance: $INSTANCE, state: $state)"
echo "  Phx logs:   $LOG_FILE"
