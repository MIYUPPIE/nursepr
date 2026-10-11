defmodule NursePrep.AiTutor.Workers.TutorWorker do
  @moduledoc """
  Runs the AI tutor call for a free-text question out-of-band from
  `Whatsapp.Session`, over WhatsApp or Telegram-a Grok API call can take
  seconds, and neither channel has a concept of a live-edited "thinking..."
  message the way the web chat does, so this dispatches from a job and
  sends one final reply rather than blocking the session GenServer (or the
  webhook) on it.

  Renamed from `WhatsappTutorWorker`: sends via `Messaging.send_text/2`
  now instead of calling `EvolutionClient` directly, so it goes through the
  same channel-dispatch `Session` itself uses rather than being a special
  case that only ever worked for WhatsApp.
  """
  use Oban.Worker, queue: :ai_tutor, max_attempts: 2

  alias NursePrep.{AiTutor, Accounts, Messaging}

  def enqueue(user_id, identity, question) do
    %{"user_id" => user_id, "identity" => identity, "question" => question}
    |> new()
    |> Oban.insert()
  end

  @doc "Enqueues the same weak-area explanation as the web tutor's quick-action button, delivered as a reply on `identity`'s channel."
  def enqueue_weak_areas(user_id, identity) do
    %{"user_id" => user_id, "identity" => identity, "kind" => "weak_areas"}
    |> new()
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "identity" => identity, "kind" => "weak_areas"}
      }) do
    user = Accounts.get_user!(user_id)
    reply = AiTutor.explain_weak_areas(user, channel(identity)) |> reply_text()
    Messaging.send_text(identity, reply)
    :ok
  end

  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "identity" => identity, "question" => question}
      }) do
    user = Accounts.get_user!(user_id)
    reply = AiTutor.ask(user, channel(identity), question) |> reply_text()
    Messaging.send_text(identity, reply)
    :ok
  end

  defp channel(identity), do: if(Messaging.telegram?(identity), do: "telegram", else: "whatsapp")

  defp reply_text({:ok, text}), do: text

  defp reply_text({:error, :rate_limited}),
    do: "You've reached the hourly limit for tutor questions-try again in a bit."

  defp reply_text({:error, :subscription_required}),
    do:
      "The AI tutor is a Premium feature. Reply \"subscribe\" to unlock unlimited practice + timed mock exams + the AI tutor."

  defp reply_text({:error, _reason}),
    do: "Sorry, the tutor is unavailable right now. Please try again shortly."
end
