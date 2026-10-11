defmodule NursePrep.Messaging do
  @moduledoc """
  The one place that knows how to tell channels apart and dispatch an
  outbound send to the right one. `Whatsapp.Session`'s identity (the
  `phone` field/column, on both the GenServer and the `whatsapp_sessions`
  row) is an opaque routing string that can be a bare E.164 phone number,
  a WhatsApp `@lid` privacy id, or-since this module exists-a tagged
  Telegram identity (`"telegram:<chat_id>"`). Every other function in the
  app (`Session`, the AI tutor worker, `OtpSender.Telegram`) goes through
  `send_text/2` here rather than picking a client itself, so channel
  detection lives in exactly one place.

  Deliberately a tagged string, not a `{channel, id}` tuple: the identity
  already has to serialize to a single `:string` column either way (the
  `whatsapp_sessions.phone` column, and the Registry/DynamicSupervisor
  key), and WhatsApp's own `@lid` identities already prove a plain string
  carries this distinction fine with zero extra encode/decode step.
  """

  alias NursePrep.Whatsapp.EvolutionClient
  alias NursePrep.Telegram.TelegramClient

  @telegram_prefix "telegram:"

  @doc "True for a tagged Telegram identity (`\"telegram:<chat_id>\"`)."
  @spec telegram?(String.t()) :: boolean()
  def telegram?("telegram:" <> _), do: true
  def telegram?(_), do: false

  @doc "True for a WhatsApp `@lid` privacy-id identity."
  @spec whatsapp_lid?(String.t()) :: boolean()
  def whatsapp_lid?(identity) when is_binary(identity), do: String.ends_with?(identity, "@lid")

  @doc "Builds the tagged identity string for a Telegram chat id."
  @spec tag_telegram(integer()) :: String.t()
  def tag_telegram(chat_id) when is_integer(chat_id),
    do: @telegram_prefix <> Integer.to_string(chat_id)

  @doc "Extracts the numeric chat id back out of a tagged Telegram identity. Raises on a non-Telegram identity-callers must check `telegram?/1` first."
  @spec telegram_chat_id(String.t()) :: integer()
  def telegram_chat_id("telegram:" <> chat_id_str), do: String.to_integer(chat_id_str)

  @doc "Sends `text` to `identity`, dispatching to the Telegram or WhatsApp client based on the identity's shape."
  @spec send_text(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_text(identity, text) do
    if telegram?(identity) do
      telegram_client().send_text(telegram_chat_id(identity), text)
    else
      evolution_client().send_text(identity, text)
    end
  end

  @doc """
  The bot's `https://t.me/<username>` deep link-what `Settings` renders as
  the "link Telegram" button, since linking is initiated from Telegram
  itself (a bot can't push to a chat id that hasn't messaged it first), not
  from a web form the way WhatsApp phone-linking is. `nil` when
  `TELEGRAM_BOT_USERNAME` isn't configured, so the settings page can hide
  the button rather than link to a broken URL.
  """
  @spec telegram_bot_url() :: String.t() | nil
  def telegram_bot_url do
    case Application.fetch_env!(:nurseprep, :telegram_api)[:bot_username] do
      nil -> nil
      username -> "https://t.me/#{username}"
    end
  end

  @doc """
  A one-tap `t.me/<bot>?start=<token>` deep link carrying a signed
  link-token-from `NursePrep.Accounts.request_telegram_link_token/1`
  (Settings) or `NursePrep.Accounts.request_otp/1`'s WhatsApp-down
  no-fallback case (login page). Tapping Telegram's auto-shown Start
  button sends the token straight to the bot as `/start <token>`, linking
  the account with no phone/email typed by hand. Same `nil`-when-
  unconfigured fallback as `telegram_bot_url/0`.
  """
  @spec telegram_deep_link(String.t()) :: String.t() | nil
  def telegram_deep_link(token) do
    case telegram_bot_url() do
      nil -> nil
      url -> "#{url}?start=#{token}"
    end
  end

  defp telegram_client, do: Application.get_env(:nurseprep, :telegram_client, TelegramClient)
  defp evolution_client, do: Application.get_env(:nurseprep, :evolution_client, EvolutionClient)
end
