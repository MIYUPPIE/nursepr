defmodule NursePrepWeb.Admin.IngestionLive do
  use NursePrepWeb, :live_view

  alias NursePrep.Questions.Ingestion

  # Configurable so tests point this at the small fixture docx instead of
  # the real ~5,000-question source file (gitignored, absent in CI, and not
  # something a test run should ever shell out to pandoc against).
  @default_docx_path Application.compile_env(
                       :nurseprep,
                       :ingestion_docx_path,
                       "priv/source_data/nursing_questions.docx"
                     )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:ingestion}>
      <.header icon="hero-arrow-up-tray">
        Docx ingestion
        <:subtitle>
          Parses the source exam file into draft questions-nothing publishes automatically.
        </:subtitle>
      </.header>

      <div class="card bg-base-100 border border-base-300 mt-4">
        <div class="card-body">
          <p class="text-sm text-base-content/70">
            Source file: <code class="bg-base-200 px-1.5 py-0.5 rounded text-xs">{@docx_path}</code>
          </p>

          <.button
            variant="primary"
            phx-click="run"
            disabled={@running}
            phx-disable-with="Running..."
            class="mt-2 w-fit"
          >
            {if @running, do: "Running...", else: "Run ingestion"}
          </.button>

          <div :if={@running} class="mt-4">
            <progress class="progress progress-primary w-full" value={@done} max={@total}></progress>
            <p class="text-sm mt-1 text-base-content/60">{@done} / {@total}</p>
          </div>

          <div :if={@summary} class="mt-4">
            <p class="font-semibold flex items-center gap-2 mb-3">
              <.icon name="hero-check-circle" class="size-5 text-success" /> Run complete
            </p>
            <ul class="text-sm space-y-1.5">
              <li class="flex items-center gap-2">
                <span class="badge badge-success badge-sm"></span>
                Created: {@summary.persisted.created}
              </li>
              <li class="flex items-center gap-2">
                <span class="badge badge-ghost badge-sm"></span>
                Skipped (already ingested): {@summary.persisted.skipped_existing}
              </li>
              <li class="flex items-center gap-2">
                <span class="badge badge-warning badge-sm"></span>
                Flagged-image: {@summary.persisted.flagged_image}
              </li>
              <li class="flex items-center gap-2">
                <span class="badge badge-warning badge-sm"></span>
                Flagged-malformed: {@summary.persisted.flagged_malformed}
              </li>
              <li class="flex items-center gap-2">
                <span class="badge badge-error badge-sm"></span>
                Flagged-no matching answer: {@summary.persisted.mismatched_answer}
              </li>
            </ul>
            <.link navigate={~p"/admin/review-queue"} class="link mt-4 inline-block">
              Go to review queue →
            </.link>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       docx_path: @default_docx_path,
       running: false,
       done: 0,
       total: 0,
       summary: nil
     )}
  end

  @impl true
  def handle_event("run", _params, socket) do
    unless File.exists?(socket.assigns.docx_path) do
      {:noreply, put_flash(socket, :error, "No file found at #{socket.assigns.docx_path}")}
    else
      topic = "ingestion:#{socket.assigns.current_scope.user.id}"
      Phoenix.PubSub.subscribe(NursePrep.PubSub, topic)
      pid = self()

      Task.Supervisor.start_child(NursePrep.TaskSupervisor, fn ->
        json_path = convert_to_json(socket.assigns.docx_path)
        result = Ingestion.run(json_path, pubsub_topic: topic)
        send(pid, {:ingestion_done, result})
      end)

      {:noreply, assign(socket, running: true, done: 0, total: 0, summary: nil)}
    end
  end

  @impl true
  def handle_info({:ingestion_progress, done, total}, socket) do
    {:noreply, assign(socket, done: done, total: total)}
  end

  def handle_info({:ingestion_done, result}, socket) do
    {:noreply, assign(socket, running: false, summary: result)}
  end

  defp convert_to_json(docx_path) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "nurseprep_ingest_#{System.unique_integer([:positive])}")

    media_dir = Path.join(tmp_dir, "media")
    json_path = Path.join(tmp_dir, "source.json")
    File.mkdir_p!(media_dir)

    {_output, 0} =
      System.cmd("pandoc", [
        docx_path,
        "-t",
        "json",
        "--extract-media=#{media_dir}",
        "-o",
        json_path
      ])

    json_path
  end
end
