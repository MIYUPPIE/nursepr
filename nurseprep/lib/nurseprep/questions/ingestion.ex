defmodule NursePrep.Questions.Ingestion do
  @moduledoc """
  Orchestrates turning a parsed docx (`DocxParser.parse_file/1` output) into
  draft `questions`/`options` rows, each paired with a `pending` review —
  nothing here ever sets `status: "published"`. Idempotent: re-running against
  the same source is always safe because of the
  `(source_section_ordinal, source_question_number)` unique index.
  """

  import Ecto.Query
  require Logger

  alias NursePrep.Repo
  alias NursePrep.Questions.Ingestion.DocxParser
  alias NursePrep.Questions.{Question, Option}

  @doc """
  Runs ingestion against a pandoc-JSON file, optionally broadcasting progress
  to `topic` over PubSub as `{:ingestion_progress, done, total}` messages, so
  `Admin.IngestionLive` can show a live progress bar for a run against the
  full ~5,000-question source file.
  """
  def run(json_path, opts \\ []) do
    topic = Keyword.get(opts, :pubsub_topic)
    {questions, image_notes, parse_summary} = DocxParser.parse_file(json_path)

    total = length(questions)

    result =
      questions
      |> Enum.with_index(1)
      |> Enum.reduce(
        %{
          created: 0,
          skipped_existing: 0,
          flagged_image: 0,
          flagged_malformed: 0,
          mismatched_answer: 0
        },
        fn {question, index}, acc ->
          acc = persist_question(question, acc)
          if topic, do: broadcast(topic, index, total)
          acc
        end
      )

    %{parse_summary: parse_summary, image_notes: length(image_notes), persisted: result}
  end

  # A single question's row/options insert runs inside its own transaction
  # (see `insert_draft/3`), but a Postgres transaction aborts entirely on the
  # *first* SQL-level error within it-Ecto's `unique_constraint` gracefully
  # converting that first error to a changeset doesn't undo that server-side
  # abort, so every subsequent statement in the same transaction (e.g. the
  # next option) fails with an unrelated-looking 25P02 "transaction aborted"
  # error that Ecto does *not* recognize as a constraint violation and
  # re-raises instead. Verified against the real source: a small number of
  # questions (parser ambiguity merging two consecutive questions' options
  # under one stem) produce duplicate-labeled options and hit exactly this.
  # The `try/rescue` here is the backstop for that class of problem and any
  # other unforeseen one across ~5,000 raw, inconsistently-formatted
  # questions-one bad row must never take the other 4,999 down with it.
  defp persist_question(parsed, acc) do
    case classify(parsed) do
      :image ->
        insert_draft(parsed, "flagged_manual_review", "flagged_image")
        %{acc | flagged_image: acc.flagged_image + 1}

      :mismatched_answer ->
        insert_draft(parsed, "flagged_manual_review", "flagged_malformed")
        %{acc | mismatched_answer: acc.mismatched_answer + 1}

      :malformed ->
        insert_draft(parsed, "flagged_manual_review", "flagged_malformed")
        %{acc | flagged_malformed: acc.flagged_malformed + 1}

      :ok ->
        case insert_draft(parsed, "draft", "ingestion_cleanup") do
          {:ok, _question} -> %{acc | created: acc.created + 1}
          {:error, :already_ingested} -> %{acc | skipped_existing: acc.skipped_existing + 1}
          {:error, _changeset} -> %{acc | flagged_malformed: acc.flagged_malformed + 1}
        end
    end
  rescue
    error ->
      Logger.warning(
        "Ingestion: question #{parsed.section_ordinal}/#{parsed.question_number} raised #{inspect(error)}-flagging instead of crashing the run"
      )

      %{acc | flagged_malformed: acc.flagged_malformed + 1}
  end

  defp classify(%{has_image: true}), do: :image

  defp classify(%{question_type: :mcq} = q) do
    cond do
      has_duplicate_labels?(q.options) -> :malformed
      is_nil(q.answer_label) -> :mismatched_answer
      Enum.any?(q.options, &(&1.label == q.answer_label)) -> :ok
      true -> :mismatched_answer
    end
  end

  defp classify(%{question_type: :fill_blank}), do: :ok
  defp classify(_), do: :malformed

  defp has_duplicate_labels?(options) do
    labels = Enum.map(options, & &1.label)
    Enum.uniq(labels) != labels
  end

  defp insert_draft(parsed, status, review_type) do
    Repo.transaction(fn ->
      question_attrs = %{
        "source_section_ordinal" => parsed.section_ordinal,
        "source_section_label" => parsed.section_label,
        "source_question_number" => parsed.question_number,
        "stem" => parsed.stem,
        "raw_stem" => parsed.stem,
        "question_type" => to_string(parsed.question_type),
        "status" => status,
        "has_image" => parsed.has_image,
        "image_path" => List.first(parsed.image_refs)
      }

      with {:ok, question} <-
             %Question{}
             |> Question.ingestion_changeset(question_attrs)
             |> Repo.insert(
               on_conflict: :nothing,
               conflict_target: [:source_section_ordinal, :source_question_number]
             ) do
        if question.id do
          insert_options(question, parsed.options, parsed.answer_label)
          insert_review(question, review_type)
          question
        else
          Repo.rollback(:already_ingested)
        end
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp insert_options(_question, [], _answer_label), do: :ok

  defp insert_options(question, options, answer_label) do
    # Dedupe by label (keep first occurrence) *before* touching the
    # database. A duplicate reaching Postgres would abort the surrounding
    # transaction-including the question row and its review-so the
    # question would silently vanish instead of landing in the review
    # queue where a human can actually see and fix the doubled options.
    # `classify/1` already routes anything with duplicates to
    # flagged_manual_review; this is what makes that row actually persist.
    options
    |> Enum.uniq_by(& &1.label)
    |> Enum.each(fn opt ->
      %Option{}
      |> Option.changeset(%{
        "question_id" => question.id,
        "label" => opt.label,
        "body" => opt.text,
        "is_correct" => opt.label == answer_label,
        "position" => option_position(opt.label)
      })
      |> Repo.insert()
    end)
  end

  defp option_position(label), do: :binary.first(label) - ?A + 1

  defp insert_review(question, review_type) do
    Repo.insert!(%NursePrep.Questions.QuestionReview{
      question_id: question.id,
      review_type: review_type,
      status: "pending"
    })
  end

  defp broadcast(topic, done, total) do
    Phoenix.PubSub.broadcast(NursePrep.PubSub, topic, {:ingestion_progress, done, total})
  end

  @doc "Total question rows created by ingestion, still awaiting review (used by IngestionLive's summary)."
  def draft_count do
    Repo.aggregate(from(q in Question, where: not is_nil(q.source_question_number)), :count)
  end
end
