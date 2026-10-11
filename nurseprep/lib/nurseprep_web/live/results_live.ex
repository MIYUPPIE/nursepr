defmodule NursePrepWeb.ResultsLive do
  use NursePrepWeb, :live_view

  alias NursePrep.Quizzes

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope}>
      <.header>
        Results
        <:subtitle>{humanize(@session.mode)} · {humanize(@session.status)}</:subtitle>
      </.header>

      <div class="card bg-gradient-to-br from-primary/10 to-primary/5 border border-primary/20 mt-4">
        <div class="card-body items-center text-center py-8">
          <div
            class={[
              "radial-progress font-bold text-3xl",
              score_accent(score_pct(@summary.correct_count, length(@session.quiz_answers)))
            ]}
            style={"--value:#{score_pct(@summary.correct_count, length(@session.quiz_answers))}; --size: 7rem; --thickness: 8px"}
            role="progressbar"
          >
            {@summary.correct_count}/{length(@session.quiz_answers)}
          </div>
          <p class="text-base-content/60 mt-3">
            {@summary.answered_count} answered · {score_pct(
              @summary.correct_count,
              length(@session.quiz_answers)
            )}% correct
          </p>
        </div>
      </div>

      <div class="flex gap-2 mt-4">
        <.link navigate={~p"/practice"} class="btn btn-primary">Practice more</.link>
        <.link navigate={~p"/dashboard"} class="btn btn-ghost">Back to dashboard</.link>
      </div>

      <.section title="Review">
        <div class="space-y-3">
          <div
            :for={{a, i} <- Enum.with_index(@session.quiz_answers, 1)}
            class="card bg-base-100 border border-base-300"
          >
            <div class="card-body">
              <p class="font-medium">{i}. {a.question.stem}</p>
              <ul class="mt-2 space-y-1">
                <li
                  :for={o <- a.question.options}
                  class={[
                    "flex items-center gap-2 p-2 rounded-lg text-sm",
                    o.is_correct && "bg-success/10",
                    !o.is_correct && o.id == a.selected_option_id && "bg-error/10"
                  ]}
                >
                  <span class="font-semibold">{o.label}.</span> {o.body}
                  <.icon
                    :if={o.is_correct}
                    name="hero-check-circle"
                    class="size-4 text-success shrink-0 ml-auto"
                  />
                  <.icon
                    :if={!o.is_correct && o.id == a.selected_option_id}
                    name="hero-x-circle"
                    class="size-4 text-error shrink-0 ml-auto"
                  />
                </li>
              </ul>
              <p :if={is_nil(a.selected_option_id)} class="text-sm text-base-content/60 italic mt-1">
                Not answered
              </p>
              <p :if={a.question.explanation} class="text-sm mt-2 text-base-content/70">
                {a.question.explanation.body}
              </p>
            </div>
          </div>
        </div>
      </.section>
    </Layouts.student>
    """
  end

  defp score_accent(pct) when pct >= 70, do: "text-success"
  defp score_accent(pct) when pct >= 40, do: "text-warning"
  defp score_accent(_pct), do: "text-error"

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    session = Quizzes.get_session!(session_id)

    if session.user_id != socket.assigns.current_scope.user.id do
      {:ok,
       socket
       |> put_flash(:error, "That session isn't yours.")
       |> push_navigate(to: ~p"/dashboard")}
    else
      {:ok, assign(socket, session: session, summary: Quizzes.session_summary(session))}
    end
  end

  defp score_pct(_correct, 0), do: 0
  defp score_pct(correct, total), do: Float.round(correct / total * 100, 1)

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
