defmodule NursePrep.Whatsapp.Workers.DailyQuizDropWorker do
  @moduledoc """
  Sends one practice question to every opted-in student, over WhatsApp or
  Telegram-whichever is actually reachable for them right now. Cron-triggered
  once daily with empty args (the fan-out trigger); that run enqueues one
  unique per-user job per opted-in student, so a slow or failing send for
  one identity can't block or crash the rest, and a retried or double-fired
  cron tick can't double-send the same user-the uniqueness window (20h) is
  shorter than a day so tomorrow's run isn't blocked by today's.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  alias NursePrep.{Accounts, Messaging}
  alias NursePrep.Whatsapp.{ConnectionAlert, Session}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "identity" => identity}}) do
    Session.send_daily_quiz(identity, user_id)
    :ok
  end

  def perform(%Oban.Job{args: %{}}) do
    Accounts.list_daily_quiz_opt_in_users()
    |> Enum.each(fn user ->
      %{user_id: user.id, identity: daily_quiz_identity(user)}
      |> new(unique: [period: 72_000, keys: [:user_id]])
      |> Oban.insert()
    end)

    :ok
  end

  # WhatsApp when it's actually up (regardless of Telegram link-most
  # students only have WhatsApp); Telegram when it's down and this student
  # linked one; otherwise best-effort phone anyway, matching this worker's
  # pre-Telegram behavior for a student with no Telegram link-a harmless,
  # already-logged failed attempt rather than a silent skip.
  defp daily_quiz_identity(%{phone: phone, telegram_chat_id: chat_id}) do
    cond do
      phone && ConnectionAlert.connected?() -> phone
      chat_id -> Messaging.tag_telegram(chat_id)
      true -> phone
    end
  end
end
