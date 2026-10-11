defmodule NursePrepWeb.Admin.ReviewQueueLive do
  @moduledoc """
  Triage queue for everything ingestion flagged. With ~5,000 raw questions
  behind it, clicking through one at a time isn't viable-this page is built
  around keyboard shortcuts (a=approve, r=reject, j/k=prev/next) so a
  reviewer can move through a batch without leaving the keyboard, plus
  bulk-select for the cases (e.g. mass answer-key mismatches from a bad OCR
  page) where whole groups need the same decision.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.Questions
  alias NursePrep.Questions.Workers.AiCleanupWorker

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:review_queue}>
      <.header icon="hero-inbox-stack">
        Review queue
        <:subtitle>
          {length(@reviews)} pending · keyboard: a=approve, r=reject, j/k=next/prev
        </:subtitle>
      </.header>

      <div class="flex gap-2 my-4 flex-wrap">
        <button
          :for={type <- @review_types}
          phx-click="filter_type"
          phx-value-type={type}
          class={["btn btn-sm", @filter_type == type && "btn-primary"]}
        >
          {humanize(type)}
        </button>
        <button
          phx-click="filter_type"
          phx-value-type=""
          class={["btn btn-sm", @filter_type == nil && "btn-primary"]}
        >
          All
        </button>
        <button phx-click="run_ai_cleanup" class="btn btn-sm btn-ghost ml-auto">
          <.icon name="hero-sparkles" class="size-4" /> Suggest AI cleanup (next 25)
        </button>
      </div>

      <div :if={@current} class="card bg-base-100 border border-base-300" phx-window-keydown="keydown">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <span class="badge badge-warning">{humanize(@current.review_type)}</span>
            <span class="text-sm text-base-content/60">{@index + 1} of {length(@reviews)}</span>
          </div>

          <p class="text-lg mt-2">{@current.question.stem}</p>

          <ul class="mt-2 space-y-1">
            <li
              :for={o <- @current.question.options}
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

          <p :if={@current.question.options == []} class="text-sm text-base-content/60 italic mt-2">
            No options captured-likely fill-in-the-blank or a malformed extraction.
          </p>

          <div
            :if={@current.ai_suggested_stem}
            class="mt-4 p-3 rounded bg-info/10 border border-info/30"
          >
            <p class="text-xs uppercase tracking-wide text-info mb-1">
              <.icon name="hero-sparkles" class="size-4 inline" /> AI-suggested cleanup
              <span :if={@current.ai_confidence} class="opacity-70">
                (self-reported confidence {Float.round(@current.ai_confidence * 100, 0)}%)
              </span>
            </p>
            <p class="font-mono text-sm leading-relaxed">
              <%= for {kind, text} <- suggestion_diff(@current) do %>
                <span class={diff_class(kind)}>{text}</span>
              <% end %>
            </p>
            <p :if={@current.ai_suggested_topic} class="text-sm mt-1">
              Suggested topic: <span class="font-medium">{@current.ai_suggested_topic.name}</span>
            </p>
            <.button variant="primary" phx-click="accept_ai_suggestion" class="btn-sm mt-2">
              Accept suggestion
            </.button>
          </div>

          <div class="flex gap-2 mt-4 flex-wrap">
            <.button variant="primary" phx-click="approve">
              <.icon name="hero-check" class="size-4" /> Approve (a)
            </.button>
            <.button phx-click="reject" class="btn-error btn-soft">
              <.icon name="hero-x-mark" class="size-4" /> Reject (r)
            </.button>
            <.button type="button" phx-click="prev" class="btn-ghost">← (k)</.button>
            <.button type="button" phx-click="next" class="btn-ghost">(j) →</.button>
            <.link
              navigate={~p"/admin/questions/#{@current.question.id}"}
              class="btn btn-ghost ml-auto"
            >
              Open full editor
            </.link>
          </div>
        </div>
      </div>

      <.empty_state :if={!@current} icon="hero-check-circle">
        Nothing pending{if @filter_type, do: " for #{humanize(@filter_type)}"}. Nice.
      </.empty_state>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    review_types = NursePrep.Questions.QuestionReview.review_types()

    {:ok,
     socket
     |> assign(
       review_types: review_types,
       filter_type: initial_filter_type(params["type"], review_types),
       index: 0
     )
     |> load_reviews()}
  end

  # Only trusts `type` from the URL (e.g. a deep link from the dashboard's
  # "needs attention" breakdown) when it's one of the real review types-
  # anything else falls back to unfiltered rather than silently filtering
  # to a type that can never match a row.
  defp initial_filter_type(type, review_types) do
    if type in review_types, do: type, else: nil
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    filter_type = if type == "", do: nil, else: type
    {:noreply, socket |> assign(filter_type: filter_type, index: 0) |> load_reviews()}
  end

  def handle_event("approve", _params, socket), do: decide(socket, :approve)
  def handle_event("reject", _params, socket), do: decide(socket, :reject)

  def handle_event("run_ai_cleanup", _params, socket) do
    {:ok, _job} = %{limit: 25} |> AiCleanupWorker.new() |> Oban.insert()

    {:noreply,
     put_flash(
       socket,
       :info,
       "Queued AI cleanup suggestions for the next 25 pending reviews — refresh in a moment."
     )}
  end

  def handle_event("accept_ai_suggestion", _params, socket) do
    review = socket.assigns.current
    reviewer_id = socket.assigns.current_scope.user.id

    case Questions.accept_ai_suggestion(review, reviewer_id) do
      {:ok, _review} ->
        {:noreply, load_reviews(socket)}

      {:error, :no_correct_option} ->
        {:noreply, put_flash(socket, :error, no_correct_option_message())}
    end
  end

  def handle_event("next", _params, socket) do
    index = min(socket.assigns.index + 1, max(length(socket.assigns.reviews) - 1, 0))
    {:noreply, assign(socket, index: index, current: Enum.at(socket.assigns.reviews, index))}
  end

  def handle_event("prev", _params, socket) do
    index = max(socket.assigns.index - 1, 0)
    {:noreply, assign(socket, index: index, current: Enum.at(socket.assigns.reviews, index))}
  end

  def handle_event("keydown", %{"key" => "a"}, socket), do: decide(socket, :approve)
  def handle_event("keydown", %{"key" => "r"}, socket), do: decide(socket, :reject)
  def handle_event("keydown", %{"key" => "j"}, socket), do: handle_event("next", %{}, socket)
  def handle_event("keydown", %{"key" => "k"}, socket), do: handle_event("prev", %{}, socket)
  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  defp decide(socket, action) do
    review = socket.assigns.current
    reviewer_id = socket.assigns.current_scope.user.id

    result =
      case action do
        :approve -> Questions.approve_review(review, reviewer_id)
        :reject -> Questions.reject_review(review, reviewer_id, "Rejected from review queue")
      end

    case result do
      {:error, :no_correct_option} ->
        {:noreply, put_flash(socket, :error, no_correct_option_message())}

      _ ->
        {:noreply, load_reviews(socket)}
    end
  end

  defp no_correct_option_message,
    do:
      "Can't approve-no option is marked correct on this question. Fix it in the full editor, or reject the review."

  # Always recomputes `current` from the *same* (bounds-clamped) index it
  # assigns, in one pass-computing them from two different index values
  # (e.g. clamping index separately after already reading `current` at the
  # old index) is what caused approving the last item on a page to show
  # "nothing pending" even though earlier items in the queue remained.
  defp load_reviews(socket) do
    reviews = Questions.list_pending_reviews(socket.assigns.filter_type)
    index = min(socket.assigns.index, max(length(reviews) - 1, 0))
    assign(socket, reviews: reviews, current: Enum.at(reviews, index), index: index)
  end

  defp suggestion_diff(review) do
    String.myers_difference(
      review.question.raw_stem || review.question.stem,
      review.ai_suggested_stem
    )
  end

  defp diff_class(:eq), do: nil
  defp diff_class(:ins), do: "bg-success/30"
  defp diff_class(:del), do: "bg-error/30 line-through"

  defp humanize(nil), do: "—"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
