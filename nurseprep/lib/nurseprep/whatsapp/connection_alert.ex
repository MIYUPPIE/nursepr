defmodule NursePrep.Whatsapp.ConnectionAlert do
  @moduledoc """
  Reacts to Evolution API's `connection.update` webhook event-the only
  signal the app gets that the paired WhatsApp session (not just the
  Evolution container) has dropped.

  This matters because the Docker healthcheck in `evolution/docker-compose.yml`
  only proves the HTTP server answers; it says nothing about the underlying
  Baileys/WhatsApp socket. A session can go from `state: "open"` to
  `state: "close"` (a WhatsApp-side logout, a `device_removed` conflict, a
  stream error) while the container keeps reporting "healthy" indefinitely-
  every reply silently fails and nobody finds out until a user complains.
  Without this handler, the webhook controller ignored `connection.update`
  entirely (see `WhatsappWebhookControllerTest` "ignores non-message
  events") and this exact failure mode sat undetected for hours.

  Alerts are debounced to one per 24 hours so a flapping connection doesn't
  spam-`state: "open"` clears the cooldown immediately so a *new* outage
  after a recovery always alerts right away.

  Also tracks live connection state (`connected?/0`), independent of the
  alert cooldown above-consumed by `Accounts.request_otp/1` and
  `DailyQuizDropWorker` to route proactive sends to the Telegram fallback
  channel when WhatsApp is down, rather than attempting a send that's
  already known to fail.

  `sync_from_evolution/0` corrects `connected?/0`'s "assume connected"
  default against Evolution's actual connection state. That default exists
  so a fresh boot never treats WhatsApp as down before the first real
  `connection.update` webhook arrives, but it stops being safe the moment a
  deploy/restart happens *during* a real outage: nothing about WhatsApp's
  state is changing (it's already down and staying down), so no new
  webhook fires to correct the assumption, and every OTP/quiz-drop
  silently keeps trying-and failing-a WhatsApp send instead of falling
  back to Telegram. This was caught in production on 2026-08-15: a deploy
  landed while WhatsApp was mid-outage, `connected?/0` came back up
  reporting `true`, and the Telegram fallback never triggered until the
  next restart.

  Called once, async, at boot (see `NursePrep.Application`) to close that
  specific deploy-during-outage window immediately, *and* every 5 minutes
  by `Whatsapp.Workers.ConnectionSyncWorker` (Oban cron) to close the wider
  one: a `connection.update` webhook missed for any reason-not just a
  deploy-would otherwise leave `connected?/0` stuck wrong for the life of
  the running node, since the webhook is the only other thing that ever
  flips it. The periodic sync is the self-healing backstop; the webhook
  handler below stays the fast path for the common case.
  """

  require Logger
  alias NursePrep.Whatsapp.AlertSender
  alias NursePrep.Whatsapp.EvolutionClient

  @alert_key {__MODULE__, :last_alert_at}
  @state_key {__MODULE__, :connection_state}
  @cooldown_seconds 86_400

  @doc """
  Whether WhatsApp is currently believed connected. Defaults to `true`
  (assume connected until a real `"close"` event says otherwise) so a
  fresh boot/deploy never treats WhatsApp as down before the first
  `connection.update` webhook arrives-defaulting the other way would
  regress every phone-based OTP request in dev, in CI, and in production
  immediately after a restart.
  """
  def connected?, do: :persistent_term.get(@state_key, :open) == :open

  @doc """
  Asks Evolution directly for the real connection state and reconciles
  `connected?/0` against it. Safe to call anytime, but only meaningfully
  corrects anything right after boot, before any real webhook has landed-
  swallows a lookup failure (Evolution unreachable, not configured, wrong
  response shape) rather than raising, since the existing "assume
  connected" default is already the correct fallback for "I don't know."
  """
  def sync_from_evolution do
    client = Application.get_env(:nurseprep, :evolution_client, EvolutionClient)

    case client.connection_state() do
      {:ok, state} -> handle_state_update(%{"state" => state})
      {:error, _reason} -> :ok
    end
  end

  def handle_state_update(%{"state" => "open"}) do
    :persistent_term.put(@state_key, :open)

    if :persistent_term.get(@alert_key, nil) do
      Logger.info("[Whatsapp] connection recovered (state: open)")
      :persistent_term.erase(@alert_key)
    end

    :ok
  end

  def handle_state_update(%{"state" => "close"} = data) do
    :persistent_term.put(@state_key, :closed)
    reason = reason(data)

    Logger.error(
      "[Whatsapp] connection closed (reason: #{reason}) — replies will silently fail until re-paired"
    )

    maybe_alert(reason)
    :ok
  end

  def handle_state_update(%{"state" => state}) do
    Logger.info("[Whatsapp] connection state: #{state}")
    :ok
  end

  def handle_state_update(_data), do: :ok

  defp reason(data), do: to_string(data["statusReason"] || data["reason"] || "unknown")

  defp maybe_alert(reason) do
    now = System.system_time(:second)
    last = :persistent_term.get(@alert_key, nil)

    if is_nil(last) or now - last >= @cooldown_seconds do
      :persistent_term.put(@alert_key, now)

      case AlertSender.deliver(reason) do
        :ok ->
          :ok

        {:error, error} ->
          Logger.error("[Whatsapp] failed to deliver disconnect alert: #{inspect(error)}")
      end
    end

    :ok
  end
end

defmodule NursePrep.Whatsapp.AlertSender do
  @moduledoc """
  Delivers the actual "WhatsApp disconnected" alert triggered by
  `NursePrep.Whatsapp.ConnectionAlert`. Mirrors
  `NursePrep.Accounts.EmailOtpSender`: swap the implementation via
  `config :nurseprep, :whatsapp_alert_sender, ...`-`.Log` (default) just
  logs, `.Mailer` sends a real email once `WHATSAPP_ALERT_EMAIL` is set.
  """

  @callback deliver(reason :: String.t()) :: :ok | {:error, term()}

  def deliver(reason), do: impl().deliver(reason)

  defp impl,
    do:
      Application.get_env(:nurseprep, :whatsapp_alert_sender, NursePrep.Whatsapp.AlertSender.Log)
end

defmodule NursePrep.Whatsapp.AlertSender.Log do
  @moduledoc "Logs the alert instead of emailing it. Default until WHATSAPP_ALERT_EMAIL is set."
  @behaviour NursePrep.Whatsapp.AlertSender

  require Logger

  @impl true
  def deliver(reason) do
    Logger.warning(
      "[Whatsapp] connection-lost alert (reason: #{reason}) not emailed — set WHATSAPP_ALERT_EMAIL to enable"
    )

    :ok
  end
end

defmodule NursePrep.Whatsapp.AlertSender.Mailer do
  @moduledoc "Delivers the connection-lost alert as a real email via Swoosh."
  @behaviour NursePrep.Whatsapp.AlertSender

  import Swoosh.Email
  alias NursePrep.Mailer

  @cooldown_hours div(86_400, 3600)

  @impl true
  def deliver(reason) do
    reason
    |> build_email()
    |> Mailer.deliver()
    |> case do
      {:ok, _metadata} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp build_email(reason) do
    to = Application.fetch_env!(:nurseprep, :whatsapp_alert_email)
    from_email = Application.get_env(:nurseprep, :mailer_from_email, "no-reply@nurseprep.ng")

    new()
    |> to(to)
    |> from({"NursePrep", from_email})
    |> subject("⚠️ NursePrep WhatsApp disconnected")
    |> text_body("""
    The paired WhatsApp session (Evolution API instance "nurseprep") just reported state "close" (reason: #{reason}).

    Every WhatsApp reply is silently failing right now. The Docker container itself keeps reporting "healthy" throughout, because its healthcheck only checks the HTTP server, not the WhatsApp connection — so this can otherwise sit unnoticed for hours.

    Fix: re-pair the number.
      ssh nurseprep-prod
      set -a; source /opt/nurseprep/.env.prod; set +a
      curl -s http://localhost:8080/instance/connect/nurseprep -H "apikey: $EVOLUTION_API_KEY" | python3 -c "import json,base64,sys; d=json.load(sys.stdin); open('/tmp/qr.png','wb').write(base64.b64decode(d['base64'].split(',',1)[1]))"
    Then scan /tmp/qr.png from the paired phone: WhatsApp -> Settings -> Linked Devices -> Link a device.

    You won't get this email again for #{@cooldown_hours} hours even if it keeps flapping.
    """)
  end
end
