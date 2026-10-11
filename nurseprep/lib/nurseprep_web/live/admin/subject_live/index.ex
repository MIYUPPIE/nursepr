defmodule NursePrepWeb.Admin.SubjectLive.Index do
  use NursePrepWeb, :live_view

  alias NursePrep.Questions
  alias NursePrep.Questions.Subject

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:subjects}>
      <.header icon="hero-book-open">
        Subjects
        <:subtitle>
          NMCN subject areas-topics live under each subject and feed the practice/exam filters.
        </:subtitle>
        <:actions>
          <.button variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New subject
          </.button>
        </:actions>
      </.header>

      <div :if={@form} class="card bg-primary/5 border border-primary/20 my-4">
        <div class="card-body">
          <h3 class="font-semibold">{if @editing, do: "Edit subject", else: "New subject"}</h3>
          <.form
            for={@form}
            id="subject-form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-2"
          >
            <.input field={@form[:name]} type="text" label="Name" required />
            <.input field={@form[:slug]} type="text" label="Slug" required />
            <.input field={@form[:description]} type="textarea" label="Description" />
            <div class="flex gap-2">
              <.button variant="primary" phx-disable-with="Saving...">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </div>
      </div>

      <.table id="subjects" rows={@subjects}>
        <:col :let={s} label="Name">{s.name}</:col>
        <:col :let={s} label="Slug"><code class="text-xs">{s.slug}</code></:col>
        <:col :let={s} label="Topics">{length(Questions.list_topics(s.id))}</:col>
        <:action :let={s}>
          <.link phx-click="edit" phx-value-id={s.id} class="link">Edit</.link>
        </:action>
      </.table>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, subjects: Questions.list_subjects(), form: nil, editing: nil)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, form: to_form(Subject.changeset(%Subject{}, %{})), editing: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    subject = Enum.find(socket.assigns.subjects, &(&1.id == String.to_integer(id)))
    {:noreply, assign(socket, form: to_form(Subject.changeset(subject, %{})), editing: subject)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: nil)}
  end

  def handle_event("validate", %{"subject" => params}, socket) do
    base = socket.assigns.editing || %Subject{}
    changeset = base |> Subject.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"subject" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Questions.create_subject(params)
        subject -> Questions.update_subject(subject, params)
      end

    case result do
      {:ok, _subject} ->
        {:noreply,
         socket
         |> assign(subjects: Questions.list_subjects(), form: nil, editing: nil)
         |> put_flash(:info, "Subject saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
