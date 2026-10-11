defmodule NursePrepWeb.WhatsappWebhookController do
  @moduledoc """
  Receives Evolution API's `messages.upsert` webhook events. Acks 200
  immediately and hands the actual work off to a supervised `Task`-the
  webhook sender expects a fast response, and `Whatsapp.Session` handling
  (DB queries, an outbound WhatsApp send) must never risk blocking that.
  """
  use NursePrepWeb, :controller

  require Logger

  alias NursePrep.Whatsapp.Session

  # Per-phone cap, independent of `Session`'s own message-id dedup: Evolution
  # sends every event type (connection.update, presence.update, message
  # receipts, ...) to this one URL, and-confirmed in production-can retry a
  # single stuck delivery up to 10 times with backoff. Without a floor here, a
  # misbehaving or spammed number can still flood `Session.handle_message/3`
  # (and this app's own outbound `send_text` quota) well past anything a real
  # 1:1 quiz conversation would ever need.
  @rate_limit_scale_ms 60_000
  @rate_limit_max_per_minute 20

  def receive(conn, params) do
    if authorized?(params) do
      handle_event(conn, params)
    else
      send_resp(conn, 401, "")
    end
  end

  defp handle_event(conn, %{"event" => "messages.upsert", "data" => data}) do
    with {phone, text, message_id} <- extract_message(data) do
      if rate_limited?(phone) do
        Logger.warning("[WhatsApp] Rate limit hit for #{phone}")
      else
        Task.Supervisor.start_child(NursePrep.TaskSupervisor, fn ->
          Session.handle_message(phone, text, message_id)
        end)
      end
    end

    send_resp(conn, 200, "")
  end

  # See `NursePrep.Whatsapp.ConnectionAlert`-this is the only signal the app
  # gets that the paired WhatsApp session (not just the Evolution container)
  # has dropped. Offloaded to a Task like the message handler above so a
  # slow SMTP send never delays the webhook ack.
  defp handle_event(conn, %{"event" => "connection.update", "data" => data}) do
    Task.Supervisor.start_child(NursePrep.TaskSupervisor, fn ->
      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(data)
    end)

    send_resp(conn, 200, "")
  end

  defp handle_event(conn, _params), do: send_resp(conn, 200, "")

  # Evolution API has no built-in webhook signature scheme, and-confirmed
  # against a live self-hosted v2.3.1 instance-it does not deliver custom
  # headers configured on a webhook (still an open upstream feature request:
  # evolution-api#1933, #2276), so a header-based shared secret can never
  # actually match. The token instead rides in the URL path, which Evolution
  # does let you set freely; `secure_compare/2` keeps the match constant-time.
  # Unset in dev (no real instance exists yet) so local testing isn't
  # blocked on a value that doesn't exist.
  defp authorized?(params) do
    case Application.fetch_env!(:nurseprep, :evolution_api)[:webhook_token] do
      nil -> true
      expected -> Plug.Crypto.secure_compare(params["token"] || "", expected)
    end
  end

  defp rate_limited?(phone) do
    case Hammer.check_rate(
           "whatsapp_webhook:#{phone}",
           @rate_limit_scale_ms,
           @rate_limit_max_per_minute
         ) do
      {:allow, _count} -> false
      {:deny, _limit} -> true
    end
  end

  # `remoteJid` isn't always a person: group chats are `<id>@g.us`, status
  # updates/broadcast lists and newsletters have their own suffixes too.
  # This bot only ever does 1:1 quiz conversations, so anything that isn't
  # a genuine individual chat is ignored outright — previously a group JID
  # like "1234-5678@g.us" fell through to `jid_to_phone/1`, produced a
  # garbage "phone number", and crashed the session GenServer on every
  # single message posted in any group the paired account belongs to.
  #
  # `@lid` is WhatsApp's newer privacy-ID address space (rolled out through
  # 2025-2026): for a growing share of contacts, `remoteJid` is an opaque
  # ID instead of a phone-based JID, and Evolution/Baileys gives us no
  # reliable way to resolve one from the other (confirmed against this live
  # v2.3.1 instance — no `remoteJidAlt` on these events; see
  # WhiskeySockets/Baileys#1718, #2414 and EvolutionAPI/evolution-api#2326,
  # #2547, all open upstream as of writing). Evolution *can* still deliver
  # a reply straight to a `@lid` address, though (confirmed by hand against
  # this instance), so unlike a group JID this isn't unusable — the raw JID
  # is passed through as `Session`'s routing key unchanged, and
  # `Session.route_lid_confirmation/2` handles turning that into a real
  # account via a one-time "what's your phone number" confirmation.
  defp extract_message(
         %{"key" => %{"remoteJid" => jid, "fromMe" => false, "id" => message_id}} = data
       ) do
    cond do
      String.ends_with?(jid, "@s.whatsapp.net") ->
        build_message(jid_to_phone(jid), data, message_id)

      String.ends_with?(jid, "@lid") ->
        build_message(jid, data, message_id)

      true ->
        :ignore
    end
  end

  defp extract_message(_data), do: :ignore

  defp build_message(routing_key, data, message_id) do
    case message_text(data["message"]) do
      nil -> :ignore
      text -> {routing_key, text, message_id}
    end
  end

  defp message_text(%{"conversation" => text}) when is_binary(text), do: text
  defp message_text(%{"extendedTextMessage" => %{"text" => text}}), do: text
  defp message_text(%{"buttonsResponseMessage" => %{"selectedButtonId" => id}}), do: id

  defp message_text(%{"listResponseMessage" => %{"singleSelectReply" => %{"selectedRowId" => id}}}),
       do: id

  defp message_text(_), do: nil

  # Evolution's remoteJid is "<number>@s.whatsapp.net"; normalize to E.164.
  defp jid_to_phone(jid) do
    jid
    |> String.split("@")
    |> List.first()
    |> then(&("+" <> &1))
  end
end
