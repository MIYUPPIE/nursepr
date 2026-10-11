defmodule NursePrep.Telegram.TelegramClient.Behaviour do
  @moduledoc "Contract for `TelegramClient`, so `Whatsapp.Session` tests can Mox-mock it instead of hitting real HTTP."

  @type chat_id :: integer()
  @type result :: {:ok, term()} | {:error, term()}

  @callback send_text(chat_id, String.t()) :: result
end
