defmodule NursePrepWeb.Admin.QuestionLive.Index do
  use NursePrepWeb, :live_view

  alias NursePrep.Questions

  @statuses ~w(draft pending_review approved published rejected flagged_manual_review)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:questions}>
      <.header icon="hero-question-mark-circle">
        Questions
        <:subtitle>{@total} matching the current filters</:subtitle>
        <:actions>
          <.button navigate={~p"/admin/questions/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New question
          </.button>
        </:actions>
      </.header>

      <form id="question-filters" phx-change="filter" class="flex flex-wrap items-center gap-3 my-4">
        <select name="status" class="select select-sm">
          <option value="">Any status</option>
          <option :for={s <- @statuses} value={s} selected={@filters[:status] == s}>
            {humanize(s)}
          </option>
        </select>
        <label class="label gap-1.5 cursor-pointer">
          <input
            type="checkbox"
            name="has_image"
            value="true"
            checked={@filters[:has_image] == true}
            class="checkbox checkbox-sm"
          /> Has image
        </label>
      </form>

      <div
        :if={@selected != []}
        class="flex items-center gap-2 mb-2 p-3 bg-primary/10 border border-primary/20 rounded-lg"
      >
        <span class="text-sm font-medium">{length(@selected)} selected</span>
        <.button phx-click="bulk_publish" class="btn-sm btn-primary">Publish</.button>
        <.button phx-click="bulk_flag" class="btn-sm btn-error btn-soft">Flag for review</.button>
      </div>

      <.empty_state :if={@questions == []} icon="hero-question-mark-circle">
        No questions match the current filters.
      </.empty_state>

      <div :if={@questions != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>
                <input type="checkbox" phx-click="toggle_select_all" class="checkbox checkbox-sm" />
              </th>
              <th>Stem</th>
              <th>Status</th>
              <th>Type</th>
              <th>Image</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={q <- @questions} class="hover:bg-base-200">
              <td>
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  checked={q.id in @selected}
                  phx-click="toggle_select"
                  phx-value-id={q.id}
                />
              </td>
              <td class="max-w-md">
                <.link navigate={~p"/admin/questions/#{q.id}"} class="link line-clamp-2">
                  {q.stem}
                </.link>
              </td>
              <td>
                <.status_badge status={q.status} />
              </td>
              <td class="text-sm">{humanize(q.question_type)}</td>
              <td>
                <.icon :if={q.has_image} name="hero-photo" class="size-4 text-warning" />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@total_pages > 1} class="flex items-center justify-between mt-4">
        <span class="text-sm text-base-content/60">
          Page {@page} of {@total_pages}
        </span>
        <div class="join">
          <.button
            phx-click="page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="join-item btn-sm"
          >
            ← Prev
          </.button>
          <.button
            phx-click="page"
            phx-value-page={@page + 1}
            disabled={@page >= @total_pages}
            class="join-item btn-sm"
          >
            Next →
          </.button>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    filters = %{}

    {:ok,
     socket
     |> assign(statuses: @statuses, filters: filters, selected: [], page: 1)
     |> load_questions()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      %{}
      |> maybe_put(:status, params["status"])
      |> maybe_put(:has_image, params["has_image"] == "true" || nil)

    {:noreply, socket |> assign(filters: filters, page: 1, selected: []) |> load_questions()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(page: String.to_integer(page)) |> load_questions()}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)

    selected =
      if id in socket.assigns.selected,
        do: List.delete(socket.assigns.selected, id),
        else: [id | socket.assigns.selected]

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    selected =
      if socket.assigns.selected == [], do: Enum.map(socket.assigns.questions, & &1.id), else: []

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("bulk_publish", _params, socket) do
    {:ok, %{published: published, skipped: skipped}} =
      Questions.bulk_publish(socket.assigns.selected)

    message =
      if skipped > 0 do
        "Published #{published} question(s). Skipped #{skipped} still awaiting review-clear their review in the queue first."
      else
        "Published #{published} question(s)."
      end

    {:noreply,
     socket
     |> assign(selected: [])
     |> load_questions()
     |> put_flash(:info, message)}
  end

  def handle_event("bulk_flag", _params, socket) do
    {:ok, count} = Questions.bulk_flag(socket.assigns.selected, "manual bulk flag from admin")

    {:noreply,
     socket
     |> assign(selected: [])
     |> load_questions()
     |> put_flash(:info, "Flagged #{count} question(s) for review.")}
  end

  defp load_questions(socket) do
    filters = Map.put(socket.assigns.filters, :page, socket.assigns.page)
    total = Questions.count_questions(socket.assigns.filters)
    total_pages = max(ceil(total / Questions.questions_per_page()), 1)

    assign(socket,
      questions: Questions.list_questions(filters),
      total: total,
      total_pages: total_pages
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp humanize(nil), do: "—"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
