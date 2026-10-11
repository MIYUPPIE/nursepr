defmodule Mix.Tasks.Nurseprep.RepairIngestionAnswers do
  @shortdoc "Recovers missing answers for questions flagged during ingestion, from a fixed docx re-parse"

  @moduledoc """
  Re-parses the source docx with the current `DocxParser` and applies any
  newly-recoverable answer directly onto matching `flagged_manual_review`
  questions still sitting in the DB from an earlier ingestion run-see
  `NursePrep.Questions.Ingestion.AnswerRepair` for what makes a question
  eligible and what "applies" means. Never touches genuinely
  malformed/duplicate-label/image questions, and never guesses.

      mix nurseprep.repair_ingestion_answers
      mix nurseprep.repair_ingestion_answers --path priv/source_data/nursing_questions.docx

  Requires `pandoc` on PATH, same as `mix nurseprep.ingest_questions`.
  """
  use Mix.Task

  alias NursePrep.Questions.Ingestion.AnswerRepair

  @default_path "priv/source_data/nursing_questions.docx"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [path: :string])
    docx_path = opts[:path] || @default_path

    unless File.exists?(docx_path) do
      Mix.raise("No file at #{docx_path}. Pass --path or place the docx at #{@default_path}.")
    end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "nurseprep_answer_repair_#{System.unique_integer([:positive])}"
      )

    json_path = Path.join(tmp_dir, "source.json")
    File.mkdir_p!(tmp_dir)

    Mix.shell().info("Converting #{docx_path} via pandoc...")

    case System.cmd("pandoc", [docx_path, "-t", "json", "-o", json_path]) do
      {_output, 0} -> :ok
      {output, _code} -> Mix.raise("pandoc failed: #{output}")
    end

    Mix.shell().info("Re-parsing and repairing...")
    result = AnswerRepair.run(json_path)

    Mix.shell().info("""

    Repaired:   #{result.repaired} question(s)-moved to draft with a fresh pending review.
    Unresolved: #{result.unresolved} question(s)-still genuinely missing an answer, left flagged.

    Review repaired questions at /admin/review-queue (type: ingestion cleanup).
    """)
  end
end
