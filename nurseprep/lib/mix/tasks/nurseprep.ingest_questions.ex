defmodule Mix.Tasks.Nurseprep.IngestQuestions do
  @shortdoc "Parses the source exam docx and loads draft questions for review"

  @moduledoc """
  Converts the source docx to pandoc JSON, parses it, and inserts draft
  questions (status: draft or flagged_manual_review) plus a pending
  `question_reviews` row for each-nothing is published automatically.

      mix nurseprep.ingest_questions
      mix nurseprep.ingest_questions --path priv/source_data/nursing_questions.docx

  Safe to re-run: already-ingested questions are skipped via the
  `(source_section_ordinal, source_question_number)` unique index.
  Requires `pandoc` on PATH.
  """
  use Mix.Task

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
      Path.join(System.tmp_dir!(), "nurseprep_ingest_#{System.unique_integer([:positive])}")

    media_dir = Path.join(tmp_dir, "media")
    json_path = Path.join(tmp_dir, "source.json")
    File.mkdir_p!(media_dir)

    Mix.shell().info("Converting #{docx_path} via pandoc...")

    case System.cmd("pandoc", [
           docx_path,
           "-t",
           "json",
           "--extract-media=#{media_dir}",
           "-o",
           json_path
         ]) do
      {_output, 0} -> :ok
      {output, _code} -> Mix.raise("pandoc failed: #{output}")
    end

    Mix.shell().info("Parsing and ingesting...")
    result = NursePrep.Questions.Ingestion.run(json_path)

    Mix.shell().info("""

    Parse summary: #{inspect(result.parse_summary)}
    Image notes captured: #{result.image_notes}

    Persisted:
      created:             #{result.persisted.created}
      skipped (existing):  #{result.persisted.skipped_existing}
      flagged (image):     #{result.persisted.flagged_image}
      flagged (malformed): #{result.persisted.flagged_malformed}
      flagged (no answer): #{result.persisted.mismatched_answer}

    Extracted media copied to: #{media_dir}
    Everything landed as draft/flagged with a pending review-nothing is published.
    Review at /admin/review-queue once the server is running.
    """)
  end
end
