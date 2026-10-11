defmodule NursePrep.Questions.Export do
  @moduledoc """
  Serializes the question bank to a single flat JSON file-one exam, one
  list, no exam-track or other area partitioning. Used to produce a
  portable, human-readable snapshot of the live bank for backup or offline
  review.
  """

  import Ecto.Query

  alias NursePrep.Repo
  alias NursePrep.Questions.Question

  @doc "Loads questions (optionally filtered by `:status`) as plain maps, ordered by id."
  def to_list(filters \\ %{}) do
    Question
    |> maybe_filter_status(filters[:status])
    |> order_by([q], asc: q.id)
    |> preload([:subject, :topic, :options, :explanation])
    |> Repo.all()
    |> Enum.map(&question_json/1)
  end

  @doc "Writes `to_list/1`'s output to `path` as pretty-printed JSON. Returns the count written."
  def write!(path, filters \\ %{}) do
    questions = to_list(filters)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(questions, pretty: true))
    length(questions)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [q], q.status == ^status)

  defp question_json(question) do
    %{
      id: question.id,
      status: question.status,
      question_type: question.question_type,
      difficulty: question.difficulty,
      stem: question.stem,
      raw_stem: question.raw_stem,
      has_image: question.has_image,
      image_path: question.image_path,
      subject: question.subject && question.subject.name,
      topic: question.topic && question.topic.name,
      source: %{
        section_ordinal: question.source_section_ordinal,
        section_label: question.source_section_label,
        question_number: question.source_question_number
      },
      options: Enum.map(question.options, &option_json/1),
      explanation: question.explanation && question.explanation.body,
      published_at: question.published_at
    }
  end

  defp option_json(option) do
    %{label: option.label, body: option.body, is_correct: option.is_correct}
  end
end
