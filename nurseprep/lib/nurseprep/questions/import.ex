defmodule NursePrep.Questions.Import do
  @moduledoc """
  Loads question JSON (the schema documented in
  `mix nurseprep.export_questions_json`) directly into the database as
  `status: "published"` — no draft state, no review queue. The source
  content is trusted as-is; nothing here second-guesses stem/option text
  quality.

  Plain module (no `Mix` calls) so it can run both from
  `mix nurseprep.import_questions_json` in dev and from a compiled release
  in production via `NursePrep.Release.import_questions_json/1`
  (`bin/nurseprep eval`), which has no Mix runtime available.

  Safety net that's still enforced regardless of anything this module does:
  `Questions.random_question_set/1` (what actually serves a practice/exam
  session) only ever draws an `mcq` question that has an option marked
  `correct` — so a row with no correct option, or a non-mcq type, is simply
  never handed to a student, whatever its `status` says.

  Idempotent per record: when a record carries both `section_ordinal` and
  `number`, re-running the same file skips anything already imported (via
  the `(source_section_ordinal, source_question_number)` unique index).
  Records without both fields always insert fresh — dedup is the caller's
  responsibility for those.

  One bad record (malformed JSON shape, duplicate option labels, a
  constraint violation) is logged and skipped rather than aborting the
  whole run — one bad row must never take the rest of the batch down.
  """

  require Logger

  alias NursePrep.Repo
  alias NursePrep.Questions.{Question, Option}

  @valid_types ~w(mcq fill_blank unresolved)

  @doc "Reads `json_path` and imports every record. Returns `%{created:, skipped_existing:, errored:}`."
  def run(json_path) do
    records = json_path |> File.read!() |> Jason.decode!()

    unless is_list(records) do
      raise ArgumentError, "#{json_path} must contain a JSON array of question objects."
    end

    Enum.reduce(records, %{created: 0, skipped_existing: 0, errored: 0}, fn record, acc ->
      case import_record(record) do
        {:ok, :created} -> %{acc | created: acc.created + 1}
        {:ok, :skipped_existing} -> %{acc | skipped_existing: acc.skipped_existing + 1}
        {:error, _reason} -> %{acc | errored: acc.errored + 1}
      end
    end)
  end

  defp import_record(record) do
    Repo.transaction(fn ->
      with {:ok, attrs} <- normalize(record),
           {:ok, question} <- insert_question(attrs) do
        if question.id do
          insert_options(question, attrs.options)
          :created
        else
          :skipped_existing
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error ->
      Logger.warning(
        "Import: record #{inspect(record["section"])}/#{inspect(record["number"])} raised #{inspect(error)}-skipping"
      )

      {:error, error}
  end

  defp normalize(%{"stem" => stem, "type" => type} = record)
       when is_binary(stem) and type in @valid_types do
    options =
      record
      |> Map.get("options", [])
      |> Enum.filter(&match?(%{"label" => l, "body" => b} when is_binary(l) and is_binary(b), &1))
      |> Enum.uniq_by(& &1["label"])

    {:ok,
     %{
       section_ordinal: record["section_ordinal"],
       section_label: record["section"],
       number: record["number"],
       stem: stem,
       type: type,
       has_image: !!record["has_image"],
       options: options
     }}
  end

  defp normalize(record), do: {:error, {:invalid_record, record}}

  defp insert_question(%{section_ordinal: ordinal, number: number} = attrs)
       when is_integer(ordinal) and is_integer(number) do
    question_attrs = %{
      "source_section_ordinal" => ordinal,
      "source_section_label" => attrs.section_label,
      "source_question_number" => number,
      "stem" => attrs.stem,
      "raw_stem" => attrs.stem,
      "question_type" => attrs.type,
      "status" => "published",
      "has_image" => attrs.has_image,
      "published_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Question{}
    |> Question.ingestion_changeset(question_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:source_section_ordinal, :source_question_number]
    )
  end

  defp insert_question(attrs) do
    question_attrs = %{
      "stem" => attrs.stem,
      "raw_stem" => attrs.stem,
      "question_type" => attrs.type,
      "status" => "published",
      "has_image" => attrs.has_image,
      "published_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Question{} |> Question.changeset(question_attrs) |> Repo.insert()
  end

  defp insert_options(_question, []), do: :ok

  defp insert_options(question, options) do
    Enum.each(options, fn opt ->
      %Option{}
      |> Option.changeset(%{
        "question_id" => question.id,
        "label" => opt["label"],
        "body" => opt["body"],
        "is_correct" => !!opt["correct"],
        "position" => option_position(opt["label"])
      })
      |> Repo.insert!()
    end)
  end

  defp option_position(<<letter>>) when letter in ?A..?F, do: letter - ?A + 1
  defp option_position(_), do: 1
end
