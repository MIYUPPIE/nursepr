defmodule NursePrepWeb.PracticeLive.Show do
  @moduledoc """
  Practice mode: untimed, instant feedback. One LiveView handles both
  starting a session (`:new`) and taking it (`:show`) since they share so
  much state (subject filter, the current session) that splitting them
  would just mean passing everything through the URL twice.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Questions, Quizzes}

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:practice}>
      <.header icon="hero-pencil-square">
        Practice
        <:subtitle>Untimed. Instant feedback.</:subtitle>
      </.header>

      <div class="card bg-base-100 border border-base-300 mt-4 max-w-md">
        <div class="card-body">
          <p class="text-sm text-base-content/70">
            Questions are drawn from the full question bank.
          </p>
          <.button
            variant="primary"
            phx-click="start"
            phx-disable-with="Starting..."
            class="w-full mt-2"
          >
            Start practice
          </.button>
        </div>
      </div>
    </Layouts.student>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:practice}>
      <.header>
        Practice
        <:actions>
          <div class="w-40 sm:w-56">
            <p class="text-xs text-base-content/60 mb-1 text-right">
              Question {@index + 1} of {length(@session.quiz_answers)}
            </p>
            <progress
              class="progress progress-primary w-full"
              value={@index + 1}
              max={length(@session.quiz_answers)}
            ></progress>
          </div>
        </:actions>
      </.header>

      <.question_card
        answer={@current}
        selected_option_id={@current.selected_option_id}
        show_feedback={@current.answered_at != nil}
      />

      <div class="flex justify-between mt-4">
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
          phx-click="finish"
          variant="primary"
        >
          Finish
        </.button>
      </div>
    </Layouts.student>
    """
  end

  attr :answer, :map, required: true
  attr :selected_option_id, :integer, default: nil
  attr :show_feedback, :boolean, default: false

  defp question_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body">
        <p class="text-lg">{@answer.question.stem}</p>

        <div class="mt-3 space-y-2">
          <button
            :for={o <- @answer.question.options}
            type="button"
            phx-click="select"
            phx-value-option_id={o.id}
            disabled={@show_feedback}
            class={[
              "w-full flex items-center gap-3 text-left p-3 rounded-lg border transition-colors",
              !@show_feedback && "hover:border-primary/60 hover:bg-primary/5",
              option_class(o, @selected_option_id, @show_feedback)
            ]}
          >
            <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-content/5 font-semibold text-sm">
              {o.label}
            </span>
            <span class="flex-1">{o.body}</span>
            <.icon
              :if={@show_feedback && o.is_correct}
              name="hero-check-circle"
              class="size-5 text-success shrink-0"
            />
            <.icon
              :if={@show_feedback && !o.is_correct && o.id == @selected_option_id}
              name="hero-x-circle"
              class="size-5 text-error shrink-0"
            />
          </button>
        </div>

        <div
          :if={@show_feedback}
          class={[
            "mt-4 p-3 rounded-lg flex gap-3",
            if(@answer.is_correct, do: "bg-success/10", else: "bg-error/10")
          ]}
        >
          <.icon
            name={if @answer.is_correct, do: "hero-check-circle", else: "hero-information-circle"}
            class={[
              "size-5 shrink-0 mt-0.5",
              if(@answer.is_correct, do: "text-success", else: "text-error")
            ]}
          />
          <div>
            <p class="font-semibold">
              {if @answer.is_correct, do: "Correct!", else: "Incorrect"}
            </p>
            <p :if={@answer.question.explanation} class="text-sm mt-1 text-base-content/80">
              {@answer.question.explanation.body}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp option_class(option, selected_id, false),
    do: if(option.id == selected_id, do: "border-primary", else: "border-base-300")

  defp option_class(option, selected_id, true) do
    cond do
      option.is_correct -> "border-success bg-success/10"
      option.id == selected_id -> "border-error bg-error/10"
      true -> "border-base-300 opacity-60"
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, assign(socket, user: user)}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    session = Quizzes.get_session!(session_id)

    if session.user_id != socket.assigns.user.id do
      {:noreply,
       socket
       |> put_flash(:error, "That session isn't yours.")
       |> push_navigate(to: ~p"/practice")}
    else
      {:noreply,
       assign(socket, session: session, index: 0, current: Enum.at(session.quiz_answers, 0))}
    end
  end

  def handle_params(params, _uri, socket) do
    topic_id = parse_id(params["topic_id"])
    subject_id = parse_id(params["subject_id"])

    cond do
      topic_id -> start_practice(socket, %{subject_id: nil, topic_id: topic_id})
      subject_id -> start_practice(socket, %{subject_id: subject_id, topic_id: nil})
      true -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start", _params, socket) do
    start_practice(socket, %{})
  end

  def handle_event("select", %{"option_id" => option_id}, socket) do
    {:ok, answer} =
      Quizzes.answer_question(
        socket.assigns.session,
        socket.assigns.current.question_id,
        String.to_integer(option_id)
      )

    session = Quizzes.get_session!(socket.assigns.session.id)
    current = Enum.find(session.quiz_answers, &(&1.id == answer.id))

    {:noreply, assign(socket, session: session, current: current)}
  end

  def handle_event("next", _params, socket) do
    index = min(socket.assigns.index + 1, length(socket.assigns.session.quiz_answers) - 1)

    {:noreply,
     assign(socket, index: index, current: Enum.at(socket.assigns.session.quiz_answers, index))}
  end

  def handle_event("prev", _params, socket) do
    index = max(socket.assigns.index - 1, 0)

    {:noreply,
     assign(socket, index: index, current: Enum.at(socket.assigns.session.quiz_answers, index))}
  end

  def handle_event("finish", _params, socket) do
    {:ok, _} = Quizzes.submit_session(socket.assigns.session)
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{socket.assigns.session.id}/results")}
  end

  defp start_practice(socket, filters) do
    with :ok <- NursePrep.Subscriptions.can_start_practice?(socket.assigns.user),
         [_ | _] <-
           Questions.random_question_set(
             limit: 1,
             subject_id: filters[:subject_id],
             topic_id: filters[:topic_id]
           ) do
      {:ok, session} = Quizzes.start_practice_session(socket.assigns.user, filters)
      {:noreply, push_navigate(socket, to: ~p"/practice/#{session.id}")}
    else
      {:error, :daily_limit_reached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You've hit today's free practice limit (#{NursePrep.Subscriptions.free_daily_practice_limit()} questions). Upgrade for unlimited practice."
         )}

      [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No published questions available yet. Check back soon."
         )}
    end
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
