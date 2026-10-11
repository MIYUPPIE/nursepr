defmodule NursePrep.Quizzes.Workers.AutoSubmitExpiredExamWorker do
  @moduledoc """
  Backstop for exam time limits. `ExamLive.Show` already checks
  `expires_at` on mount and on every answer, but a student who just closes
  the tab (no more requests to trigger that check) would otherwise stay
  `in_progress` forever-this cron sweeps those up on a schedule
  independent of any client ever reconnecting.

  For a `web` session that's enough-the client-side countdown already
  handles the user-facing "time's up" redirect, so this is a pure
  backstop. A `whatsapp` or `telegram` session has no client-side timer at
  all, so without an explicit push here a student who steps away mid-exam
  would never learn it ended.
  """
  use Oban.Worker, queue: :exams, max_attempts: 3

  alias NursePrep.{Messaging, Quizzes}
  alias NursePrep.Whatsapp.Session, as: WhatsappSession

  @impl true
  def perform(_job) do
    Quizzes.expire_overdue_exams()
    |> Enum.each(&notify_if_bot_channel/1)

    :ok
  end

  defp notify_if_bot_channel(%{channel: "whatsapp", user: %{phone: phone}} = session)
       when is_binary(phone) do
    WhatsappSession.notify_exam_expired(phone, session.id)
  end

  defp notify_if_bot_channel(%{channel: "telegram", user: %{telegram_chat_id: chat_id}} = session)
       when is_integer(chat_id) do
    WhatsappSession.notify_exam_expired(Messaging.tag_telegram(chat_id), session.id)
  end

  defp notify_if_bot_channel(_session), do: :ok
end
