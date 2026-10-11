# Evolution API (local dev)

Self-hosted WhatsApp gateway ([doc.evolution-api.com](https://doc.evolution-api.com/)) that
this project's `EvolutionClient` and `WhatsappWebhookController` talk to. This directory spins
one up locally in Docker so WhatsApp login/quiz/tutor flows can be exercised against a real
WhatsApp number without touching a shared/production instance.

Isolated from the app's own Postgres: this stack runs its own `evolution-postgres` on host port
`5434` (the app's dev DB stays on `5432`) and its own Redis, both in named Docker volumes.

## Setup

```
cd evolution
cp .env.example .env   # then set AUTHENTICATION_API_KEY to a real random value
docker compose up -d
```

Wait for the healthcheck:

```
docker inspect --format='{{.State.Health.Status}}' nurseprep_evolution_api
```

## Create an instance and pair a real phone

```
source .env

# Create the instance with the app's webhook wired up. CONNECTION_UPDATE
# is included alongside MESSAGES_UPSERT so NursePrep.Whatsapp.ConnectionAlert
# actually hears about it when the paired session drops-Evolution's own
# Docker healthcheck only proves the HTTP server is up, not that the
# WhatsApp socket is still connected, so without this a dead session (a
# WhatsApp-side logout, a "device_removed" conflict, ...) can silently sit
# for hours with every reply failing before anyone notices.
curl -s -X POST http://localhost:8080/instance/create \
  -H "Content-Type: application/json" \
  -H "apikey: $AUTHENTICATION_API_KEY" \
  -d '{
    "instanceName": "nurseprep",
    "integration": "WHATSAPP-BAILEYS",
    "qrcode": true,
    "webhook": {
      "url": "http://host.docker.internal:4000/webhooks/evolution",
      "byEvents": false,
      "base64": false,
      "events": ["MESSAGES_UPSERT", "CONNECTION_UPDATE"]
    }
  }'

# Fetch (or re-fetch, if the first QR expired) a QR code
curl -s http://localhost:8080/instance/connect/nurseprep \
  -H "apikey: $AUTHENTICATION_API_KEY" | \
  python3 -c "import json,base64,sys; d=json.load(sys.stdin); open('qr.png','wb').write(base64.b64decode(d['base64'].split(',',1)[1]))"

xdg-open qr.png
```

Scan `qr.png` from the target phone: WhatsApp → Settings → Linked Devices → Link a device.
QR codes expire quickly (Evolution regenerates one every ~30s while `state` is `connecting`) —
if it goes stale, just re-run the `connect` call above for a fresh one.

Check pairing status:

```
curl -s http://localhost:8080/instance/connectionState/nurseprep -H "apikey: $AUTHENTICATION_API_KEY"
# {"instance":{"instanceName":"nurseprep","state":"open"}}   <- paired
```

## Point the Phoenix app at it

Export these before starting `mix phx.server` (or put them in a `.envrc`/`direnv` setup):

```
export EVOLUTION_API_BASE_URL=http://localhost:8080
export EVOLUTION_API_INSTANCE=nurseprep
export EVOLUTION_API_KEY=<value of AUTHENTICATION_API_KEY from evolution/.env>
# EVOLUTION_WEBHOOK_TOKEN intentionally left unset locally-see caveat below.
```

Restart the server so `config/runtime.exs` picks them up. Once `EVOLUTION_API_BASE_URL` is set,
`NursePrep.Accounts.OtpSender.Evolution` takes over from the dev log-only sender automatically
(`config/runtime.exs:38`), so login OTPs now go out as real WhatsApp messages to whatever number
you request a login code for.

## Known limitation: webhook custom headers aren't sent by self-hosted Evolution API

Self-hosted Evolution API v2 **silently drops custom webhook headers**-confirmed against a
live v2.3.0 instance here (`webhook/find` shows `"headers":{"apikey":""}"` no matter what's
posted to `webhook/set` or passed inline at `instance/create`), and matches two still-open
upstream feature requests asking for the capability
([#1933](https://github.com/EvolutionAPI/evolution-api/issues/1933),
[#2276](https://github.com/EvolutionAPI/evolution-api/issues/2276)). A header-based shared
secret can therefore never actually be checked.

**Fixed**: the shared secret rides in the URL path instead, which Evolution does let you set
freely. The route is `POST /webhooks/evolution/:token`
(`lib/nurseprep_web/router.ex`), and `WhatsappWebhookController.authorized?/2` compares
`params["token"]` against `EVOLUTION_WEBHOOK_TOKEN` with `Plug.Crypto.secure_compare/2`. When
`EVOLUTION_WEBHOOK_TOKEN` is unset (local dev, no real instance to protect), `authorized?/2`
falls back to "allow all"-fine for an instance nothing else can reach, but production always
sets the token and points the webhook at the full `/webhooks/evolution/<token>` URL (done
automatically for the prod instance; see the root `README.md`'s "Production deployment"
section).

## Tear down

```
docker compose down          # keep volumes (instance stays paired)
docker compose down -v       # also wipe volumes (re-pairing required next time)
```
