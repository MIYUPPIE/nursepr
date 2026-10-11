defmodule NursePrepWeb.Admin.QuestionLive.New do
  use NursePrepWeb, :live_view

  alias NursePrep.Questions
  alias NursePrep.Questions.Question

  @statuses Question.statuses()
  @question_types Question.question_types()
  @difficulties Question.difficulties()
  @option_labels ~w(A B C D E F)
  @min_options 2
  @max_options 6

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:questions}>
      <.header icon="hero-plus-circle">
        New question
        <:subtitle>Hand-author a question for the bank</:subtitle>
        <:actions>
          <.button navigate={~p"/admin/questions"}>Cancel</.button>
        </:actions>
      </.header>

      <.form for={@form} id="question-form" phx-change="validate" phx-submit="save" class="mt-4">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h3 class="font-semibold mb-2">Details</h3>

            <.input field={@form[:stem]} type="textarea" label="Stem" rows="4" />

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:question_type]}
                type="select"
                label="Question type"
                prompt="Choose a type"
                options={Enum.map(@question_types, &{humanize(&1), &1})}
              />
              <.input
                field={@form[:subject_id]}
                type="select"
                label="Subject"
                prompt="Unassigned"
                options={Enum.map(@subjects, &{&1.name, &1.id})}
              />
              <.input
                field={@form[:topic_id]}
                type="select"
                label="Topic"
                prompt="Unassigned"
                options={Enum.map(@topics, &{&1.name, &1.id})}
                disabled={@topics == []}
              />
              <.input
                field={@form[:difficulty]}
                type="select"
                label="Difficulty"
                prompt="Unset"
                options={Enum.map(@difficulties, &{humanize(&1), &1})}
              />
              <.input
                field={@form[:status]}
                type="select"
                label="Status"
                options={Enum.map(@statuses, &{humanize(&1), &1})}
              />
            </div>

            <.input field={@form[:has_image]} type="checkbox" label="Has image" />
            <.input
              field={@form[:image_path]}
              type="text"
              label="Image path"
              placeholder="e.g. /uploads/questions/123.png"
            />
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 mt-4">
          <div class="card-body">
            <h3 class="font-semibold">Options</h3>
            <p class="text-sm text-base-content/60 mb-3">
              Select the radio button next to the correct option.
            </p>

            <div class="space-y-2">
              <div
                :for={{row, idx} <- Enum.with_index(@option_rows)}
                class={[
                  "flex items-center gap-2 p-2 rounded-lg border transition-colors",
                  if(@correct_index == to_string(idx),
                    do: "border-success/40 bg-success/5",
                    else: "border-transparent"
                  )
                ]}
              >
                <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-content/5 font-semibold text-sm">
                  {Enum.at(@option_labels, idx)}
                </span>
                <input
                  type="radio"
                  name="correct_option"
                  value={idx}
                  checked={@correct_index == to_string(idx)}
                  class="radio radio-sm radio-success"
                  aria-label={"Mark option #{Enum.at(@option_labels, idx)} as correct"}
                />
                <input
                  type="text"
                  name={"options[#{idx}][body]"}
                  value={row["body"]}
                  placeholder={"Option #{Enum.at(@option_labels, idx)} text"}
                  class="input flex-1"
                />
                <button
                  :if={length(@option_rows) > @min_options}
                  type="button"
                  phx-click="remove_option"
                  phx-value-index={idx}
                  class="btn btn-sm btn-ghost btn-square"
                  aria-label={"Remove option #{Enum.at(@option_labels, idx)}"}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <.button
              type="button"
              phx-click="add_option"
              class="btn-sm mt-3"
              disabled={length(@option_rows) >= @max_options}
            >
              Add option
            </.button>
          </div>
        </div>

        <div class="flex gap-2 mt-4">
          <.button type="submit" variant="primary" phx-disable-with="Creating...">
            Create question
          </.button>
          <.button type="button" navigate={~p"/admin/questions"}>Cancel</.button>
        </div>
      </.form>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Question.changeset(%Question{status: "draft"}, %{})

    {:ok,
     socket
     |> assign(
       subjects: Questions.list_subjects(),
       topics: [],
       statuses: @statuses,
       question_types: @question_types,
       difficulties: @difficulties,
       option_labels: @option_labels,
       min_options: @min_options,
       max_options: @max_options,
       option_rows: default_option_rows(),
       correct_index: nil
     )
     |> assign(form: to_form(changeset, as: "question"))}
  end

  @impl true
  def handle_event("validate", params, socket) do
    question_params = params["question"] || %{}

    topics =
      case question_params["subject_id"] do
        id when id not in [nil, ""] -> Questions.list_topics(id)
        _ -> []
      end

    changeset =
      %Question{}
      |> Question.changeset(question_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(
       topics: topics,
       option_rows: rows_from_params(params["options"], socket.assigns.option_rows),
       correct_index: params["correct_option"]
     )
     |> assign(form: to_form(changeset, as: "question"))}
  end

  def handle_event("add_option", _params, socket) do
    if length(socket.assigns.option_rows) >= @max_options do
      {:noreply, socket}
    else
      {:noreply, update(socket, :option_rows, &(&1 ++ [%{"body" => ""}]))}
    end
  end

  def handle_event("remove_option", %{"index" => index}, socket) do
    index = String.to_integer(index)

    if length(socket.assigns.option_rows) <= @min_options do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         option_rows: List.delete_at(socket.assigns.option_rows, index),
         correct_index: adjust_correct_index(socket.assigns.correct_index, index)
       )}
    end
  end

  def handle_event("save", params, socket) do
    question_params = params["question"] || %{}
    option_attrs = build_option_attrs(params["options"], params["correct_option"])

    cond do
      length(option_attrs) < @min_options ->
        {:noreply, put_flash(socket, :error, "Add at least #{@min_options} options with text.")}

      not Enum.any?(option_attrs, & &1["is_correct"]) ->
        {:noreply, put_flash(socket, :error, "Mark one option as correct.")}

      true ->
        case Questions.create_question(question_params, option_attrs) do
          {:ok, question} ->
            {:noreply,
             socket
             |> put_flash(:info, "Question created.")
             |> push_navigate(to: ~p"/admin/questions/#{question.id}")}

          {:error, %Ecto.Changeset{data: %Question{}} = changeset} ->
            {:noreply, assign(socket, form: to_form(changeset, as: "question"))}

          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Could not save options: #{error_summary(changeset)}")}
        end
    end
  end

  defp default_option_rows, do: for(_ <- 1..4, do: %{"body" => ""})

  defp rows_from_params(nil, current_rows), do: current_rows

  defp rows_from_params(params, current_rows) do
    current_rows
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      case params[to_string(idx)] do
        %{"body" => body} -> %{"body" => body}
        _ -> row
      end
    end)
  end

  defp adjust_correct_index(nil, _removed_index), do: nil

  defp adjust_correct_index(correct_index, removed_index) do
    case String.to_integer(correct_index) do
      ^removed_index -> nil
      i when i > removed_index -> to_string(i - 1)
      _ -> correct_index
    end
  end

  defp build_option_attrs(nil, _correct_index), do: []

  defp build_option_attrs(params, correct_index) do
    params
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.reject(fn {_idx, row} -> String.trim(row["body"] || "") == "" end)
    |> Enum.with_index()
    |> Enum.map(fn {{idx, row}, position} ->
      %{
        "label" => Enum.at(@option_labels, position),
        "body" => row["body"],
        "is_correct" => idx == correct_index,
        "position" => position + 1
      }
    end)
  end

  defp error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, errs} -> "#{field}: #{Enum.join(errs, ", ")}" end)
  end

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
