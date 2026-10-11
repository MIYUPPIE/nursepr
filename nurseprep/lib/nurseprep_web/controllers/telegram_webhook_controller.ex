defmodule NursePrepWeb.TelegramWebhookController do
  @moduledoc """
  Receives Telegram's `Update` webhook events. Acks 200 immediately and
  hands the actual work off to a supervised `Task`-same reasoning as
  `WhatsappWebhookController`: `Whatsapp.Session` handling (DB queries, an
  outbound send) must never risk blocking the webhook response.
  """
  use NursePrepWeb, :controller

  require Logger

  alias NursePrep.Messaging
  alias NursePrep.Whatsapp.Session

  # Same per-chat floor as the WhatsApp webhook, same reasoning: Telegram
  # posts every update type to this one URL, so a misbehaving or spammed
  # chat shouldn't be able to flood `Session.handle_message/3` past
  # anything a real 1:1 quiz conversation would need.
  @rate_limit_scale_ms 60_000
  @rate_limit_max_per_minute 20

  def receive(conn, params) do
    if authorized?(conn) do
      handle_update(conn, params)
    else
      send_resp(conn, 401, "")
    end
  end

  # `chat.type` must be exactly "private" — Telegram bots can be added to
  # groups/supergroups/channels too, and this bot only ever does 1:1 quiz
  # conversations, same restriction as WhatsApp's `@g.us` filtering.
  # `text` absent (photos, stickers, voice notes, etc.) also falls through
  # to the catch-all below. No `fromMe`-equivalent filter is needed:
  # Telegram's Bot API only ever delivers messages *to* the bot, never
  # echoes the bot's own sends back the way Evolution does.
  defp handle_update(conn, %{
         "update_id" => update_id,
         "message" => %{"chat" => %{"id" => chat_id, "type" => "private"}, "text" => text}
       })
       when is_binary(text) do
    if rate_limited?(chat_id) do
      Logger.warning("[Telegram] Rate limit hit for chat #{chat_id}")
    else
      identity = Messaging.tag_telegram(chat_id)

      Task.Supervisor.start_child(NursePrep.TaskSupervisor, fn ->
        Session.handle_message(identity, text, to_string(update_id))
      end)
    end

    send_resp(conn, 200, "")
  end

  defp handle_update(conn, _params), do: send_resp(conn, 200, "")

  # Unlike Evolution API, Telegram's `setWebhook` natively supports a
  # `secret_token` delivered as this header on every call-no path-secret
  # workaround needed here. `nil` config (dev, no real bot registered yet)
  # means always-authorized, same fallback as the WhatsApp webhook.
  defp authorized?(conn) do
    case Application.fetch_env!(:nurseprep, :telegram_api)[:webhook_secret] do
      nil ->
        true

      expected ->
        actual = conn |> get_req_header("x-telegram-bot-api-secret-token") |> List.first() || ""
        Plug.Crypto.secure_compare(actual, expected)
    end
  end

  defp rate_limited?(chat_id) do
    case Hammer.check_rate(
           "telegram_webhook:#{chat_id}",
           @rate_limit_scale_ms,
           @rate_limit_max_per_minute
         ) do
      {:allow, _count} -> false
      {:deny, _limit} -> true
    end
  end
end
