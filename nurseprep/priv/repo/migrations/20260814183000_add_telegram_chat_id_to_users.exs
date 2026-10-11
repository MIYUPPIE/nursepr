defmodule NursePrep.Repo.Migrations.AddTelegramChatIdToUsers do
  use Ecto.Migration

  # Telegram fallback channel (see NursePrep.Messaging, NursePrep.Telegram.TelegramClient):
  # a bot can only push a message to a chat id that has messaged it at least
  # once, so a student links their account by starting a chat with the bot
  # and confirming their phone/email (see
  # `Whatsapp.Session.route_telegram_confirmation/2`). This remembers that
  # mapping. `:bigint` not `:string`: Telegram's own docs note chat ids can
  # need up to 52 significant bits, so a 64-bit integer column is the right
  # (and smaller/faster-indexed) fit, not an opaque string like whatsapp_lid.
  def change do
    alter table(:users) do
      add :telegram_chat_id, :bigint
    end

    create unique_index(:users, [:telegram_chat_id])
  end
end
