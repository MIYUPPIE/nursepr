defmodule NursePrepWeb.ExamLive.Show do
  @moduledoc """
  Timed mock exam. Unlike practice mode, no per-question feedback-you
  only find out what you got right on the results page, matching the real
  NMCN exam experience. The visible countdown is a client-side hook purely
  for UX; the actual deadline is enforced server-side (both by
  `Quizzes.AutoSubmitExpiredExamWorker` on a cron, and by re-checking
  `expires_at` on every answer submission here) so a closed tab or clock
  skew can't extend real exam time.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Questions, Quizzes}

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:exam}>
      <.header icon="hero-clock">
        Mock exam
        <:subtitle>
          {@format.question_count} questions · {div(@format.time_limit_seconds, 60)} minutes · NMCN format
        </:subtitle>
      </.header>

      <div class="card bg-base-100 border border-base-300 mt-4 max-w-md">
        <div class="card-body">
          <div class="grid grid-cols-2 gap-3 text-center mb-2">
            <div class="rounded-lg bg-base-200 p-3">
              <p class="text-2xl font-bold">{@format.question_count}</p>
              <p class="text-xs text-base-content/60 uppercase tracking-wide">Questions</p>
            </div>
            <div class="rounded-lg bg-base-200 p-3">
              <p class="text-2xl font-bold">{div(@format.time_limit_seconds, 60)}</p>
              <p class="text-xs text-base-content/60 uppercase tracking-wide">Minutes</p>
            </div>
          </div>
          <p class="text-sm text-base-content/60">
            No feedback until you submit-just like the real NMCN exam.
          </p>
          <.button
            variant="primary"
            phx-click="start"
            phx-disable-with="Starting..."
            class="w-full mt-2"
          >
            Start exam
          </.button>
        </div>
      </div>
    </Layouts.student>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:exam}>
      <.header>
        Mock exam
        <:actions>
          <div class="flex items-center gap-3 flex-wrap justify-end">
            <span class="text-sm text-base-content/60">
              Question {@index + 1} of {length(@session.quiz_answers)}
            </span>
            <span
              id="exam-timer"
              phx-hook=".ExamTimer"
              data-expires-at={DateTime.to_iso8601(@session.expires_at)}
              class="font-mono font-bold badge badge-lg badge-warning gap-1.5"
            >
              <.icon name="hero-clock" class="size-4" /> --:--
            </span>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".ExamTimer">
            export default {
              mounted() {
                this.tick()
                this.timer = setInterval(() => this.tick(), 1000)
              },
              destroyed() {
                clearInterval(this.timer)
              },
              tick() {
                const expiresAt = new Date(this.el.dataset.expiresAt).getTime()
                const remainingMs = expiresAt - Date.now()

                if (remainingMs <= 0) {
                  this.el.textContent = "00:00"
                  clearInterval(this.timer)
                  this.pushEvent("time_up", {})
                  return
                }

                const totalSeconds = Math.floor(remainingMs / 1000)
                const minutes = Math.floor(totalSeconds / 60)
                const seconds = totalSeconds % 60
                this.el.textContent = `${minutes}:${seconds.toString().padStart(2, "0")}`
              }
            }
          </script>
        </:actions>
      </.header>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <p class="text-lg">{@current.question.stem}</p>

          <div class="mt-3 space-y-2">
            <button
              :for={o <- @current.question.options}
              type="button"
              phx-click="select"
              phx-value-option_id={o.id}
              class={[
                "w-full flex items-center gap-3 text-left p-3 rounded-lg border transition-colors hover:border-primary/60 hover:bg-primary/5",
                (o.id == @current.selected_option_id && "border-primary bg-primary/10") ||
                  "border-base-300"
              ]}
            >
              <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-content/5 font-semibold text-sm">
                {o.label}
              </span>
              <span class="flex-1">{o.body}</span>
              <.icon
                :if={o.id == @current.selected_option_id}
                name="hero-check-circle"
                class="size-5 text-primary shrink-0"
              />
            </button>
          </div>
        </div>
      </div>

      <div class="mt-4 space-y-3">
        <div class="flex gap-2 overflow-x-auto pb-1 -mx-4 px-4 sm:mx-0 sm:px-0">
          <button
            :for={{a, i} <- Enum.with_index(@session.quiz_answers)}
            type="button"
            phx-click="jump"
            phx-value-index={i}
            class={[
              "size-8 shrink-0 rounded-md text-xs font-semibold transition-colors",
              i == @index && "bg-primary text-primary-content",
              i != @index && a.selected_option_id && "bg-success/30 hover:bg-success/40",
              i != @index && !a.selected_option_id && "bg-base-300 hover:bg-base-content/20"
            ]}
          >
            {i + 1}
          </button>
        </div>

        <div class="flex justify-between gap-2">
          <.button type="button" phx-click="prev" class="btn-ghost" disabled={@index == 0}>← Previous</.button>
          <.button
            :if={@index < length(@session.quiz_answers) - 1}
            type="button"
            phx-click="next"
            variant="primary"
          >
            Next →
          </.button>
          <.button
            :if={@index == length(@session.quiz_answers) - 1}
            type="button"
            phx-click="submit"
            variant="primary"
          >
            Submit exam
          </.button>
        </div>
      </div>
    </Layouts.student>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, assign(socket, user: user)}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    session = Quizzes.get_session!(session_id)

    cond do
      session.user_id != socket.assigns.user.id ->
        {:noreply,
         socket |> put_flash(:error, "That exam isn't yours.") |> push_navigate(to: ~p"/exam/new")}

      session.status != "in_progress" ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}/results")}

      DateTime.compare(DateTime.utc_now(), session.expires_at) == :gt ->
        {:ok, _} = Quizzes.submit_session(session, "expired")
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}/results")}

      true ->
        {:noreply,
         assign(socket, session: session, index: 0, current: Enum.at(session.quiz_answers, 0))}
    end
  end

  def handle_params(_params, _uri, socket) do
    format = Quizzes.exam_format()

    {:noreply,
     assign(socket,
       format: %{
         question_count: format[:question_count],
         time_limit_seconds: format[:time_limit_minutes] * 60
       }
     )}
  end

  @impl true
  def handle_event("start", _params, socket) do
    with :ok <- NursePrep.Subscriptions.can_start_exam?(socket.assigns.user),
         [_ | _] <- Questions.random_question_set(limit: 1) do
      {:ok, session} = Quizzes.start_exam_session(socket.assigns.user)
      {:noreply, push_navigate(socket, to: ~p"/exam/#{session.id}")}
    else
      {:error, :subscription_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Mock exams are a Premium feature. Upgrade under Subscription to unlock timed exams."
         )}

      [] ->
        {:noreply,
         put_flash(socket, :error, "No published questions available for a mock exam yet.")}
    end
  end

  def handle_event("select", %{"option_id" => option_id}, socket) do
    if expired?(socket.assigns.session) do
      {:noreply, expire_and_redirect(socket)}
    else
      {:ok, _} =
        Quizzes.answer_question(
          socket.assigns.session,
          socket.assigns.current.question_id,
          String.to_integer(option_id)
        )

      session = Quizzes.get_session!(socket.assigns.session.id)
      current = Enum.at(session.quiz_answers, socket.assigns.index)
      {:noreply, assign(socket, session: session, current: current)}
    end
  end

  def handle_event("next", _params, socket),
    do: {:noreply, jump_to(socket, socket.assigns.index + 1)}

  def handle_event("prev", _params, socket),
    do: {:noreply, jump_to(socket, socket.assigns.index - 1)}

  def handle_event("jump", %{"index" => index}, socket),
    do: {:noreply, jump_to(socket, String.to_integer(index))}

  def handle_event("submit", _params, socket) do
    {:ok, _} = Quizzes.submit_session(socket.assigns.session)
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{socket.assigns.session.id}/results")}
  end

  def handle_event("time_up", _params, socket), do: {:noreply, expire_and_redirect(socket)}

  defp jump_to(socket, index) do
    index = index |> max(0) |> min(length(socket.assigns.session.quiz_answers) - 1)
    assign(socket, index: index, current: Enum.at(socket.assigns.session.quiz_answers, index))
  end

  defp expired?(session), do: DateTime.compare(DateTime.utc_now(), session.expires_at) == :gt

  defp expire_and_redirect(socket) do
    {:ok, _} = Quizzes.submit_session(socket.assigns.session, "expired")

    socket
    |> put_flash(:info, "Time's up! Your exam was submitted automatically.")
    |> push_navigate(to: ~p"/sessions/#{socket.assigns.session.id}/results")
  end
end
