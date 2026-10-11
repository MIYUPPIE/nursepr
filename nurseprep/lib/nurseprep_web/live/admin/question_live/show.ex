defmodule NursePrepWeb.Admin.QuestionLive.Show do
  use NursePrepWeb, :live_view

  alias NursePrep.Questions

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:questions}>
      <.header icon="hero-question-mark-circle">
        Question #{@question.id}
        <:subtitle>
          {@question.source_section_label || "hand-authored"} #{@question.source_question_number}
        </:subtitle>
        <:actions>
          <.status_badge status={@question.status} class="badge-md" />
        </:actions>
      </.header>

      <div class="card bg-base-100 border border-base-300 mt-4">
        <div class="card-body">
          <h3 class="font-semibold mb-2">Stem</h3>
          <div :if={@question.raw_stem && @question.raw_stem != @question.stem} class="mb-3">
            <p class="text-xs uppercase text-base-content/60 mb-1">Diff vs. original OCR text</p>
            <p class="font-mono text-sm leading-relaxed">
              <%= for {kind, text} <- @diff do %>
                <span class={diff_class(kind)}>{text}</span>
              <% end %>
            </p>
          </div>
          <p class="text-lg">{@question.stem}</p>

          <ul class="mt-4 space-y-1">
            <li
              :for={o <- @question.options}
              class={["flex items-center gap-2 p-2 rounded-lg", o.is_correct && "bg-success/10"]}
            >
              <span class="font-semibold">{o.label}.</span> {o.body}
              <.icon
                :if={o.is_correct}
                name="hero-check-circle"
                class="size-4 text-success ml-auto shrink-0"
              />
            </li>
          </ul>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 mt-4">
        <div class="card-body">
          <h3 class="font-semibold mb-2">Explanation</h3>
          <.form for={@explanation_form} phx-submit="save_explanation">
            <.input field={@explanation_form[:body]} type="textarea" label="Explanation body" />
            <.button variant="primary" phx-disable-with="Saving...">Save explanation</.button>
          </.form>
        </div>
      </div>

      <div :if={@question.question_reviews != []} class="card bg-base-100 border border-base-300 mt-4">
        <div class="card-body">
          <h3 class="font-semibold mb-2">Review history</h3>
          <ul class="space-y-2">
            <li :for={r <- @question.question_reviews} class="text-sm flex items-center gap-2">
              <.status_badge status={r.status} />
              <span>{humanize(r.review_type)}</span>
              <span :if={r.reviewer_notes} class="text-base-content/60">— {r.reviewer_notes}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="flex gap-2 mt-4">
        <.button :if={@question.status != "published"} variant="primary" phx-click="publish">
          Publish
        </.button>
        <.button
          :if={@question.status != "flagged_manual_review"}
          phx-click="flag"
          class="btn-error btn-soft"
        >
          Flag for manual review
        </.button>
      </div>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    question = Questions.get_question!(id)

    diff =
      if question.raw_stem && question.raw_stem != question.stem do
        String.myers_difference(question.raw_stem, question.stem)
      else
        []
      end

    explanation_changeset =
      Ecto.Changeset.change(question.explanation || %NursePrep.Questions.Explanation{}, %{})

    {:ok,
     socket
     |> assign(question: question, diff: diff)
     |> assign(explanation_form: to_form(explanation_changeset, as: "explanation"))}
  end

  @impl true
  def handle_event("save_explanation", %{"explanation" => params}, socket) do
    case Questions.upsert_explanation(
           socket.assigns.question.id,
           Map.put(params, "generated_by", "human")
         ) do
      {:ok, _explanation} ->
        {:noreply,
         socket
         |> assign(question: Questions.get_question!(socket.assigns.question.id))
         |> put_flash(:info, "Explanation saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, explanation_form: to_form(changeset, as: "explanation"))}
    end
  end

  def handle_event("publish", _params, socket) do
    {:ok, %{skipped: skipped}} = Questions.bulk_publish([socket.assigns.question.id])

    socket =
      if skipped > 0 do
        put_flash(
          socket,
          :error,
          "Can't publish-this question still has a pending review. Clear it from the review queue first."
        )
      else
        put_flash(socket, :info, "Question published.")
      end

    {:noreply, assign(socket, question: Questions.get_question!(socket.assigns.question.id))}
  end

  def handle_event("flag", _params, socket) do
    {:ok, _} =
      Questions.bulk_flag([socket.assigns.question.id], "manually flagged from question page")

    {:noreply, assign(socket, question: Questions.get_question!(socket.assigns.question.id))}
  end

  defp diff_class(:eq), do: nil
  defp diff_class(:ins), do: "bg-success/30"
  defp diff_class(:del), do: "bg-error/30 line-through"

  defp humanize(nil), do: "—"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
