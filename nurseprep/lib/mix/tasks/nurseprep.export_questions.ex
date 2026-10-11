defmodule Mix.Tasks.Nurseprep.ExportQuestions do
  @shortdoc "Dumps the entire question bank to a single flat JSON file"

  @moduledoc """
  Writes every question (id, status, stem, options, correct answer, subject,
  topic, explanation, and ingestion provenance) to one JSON file-a
  portable, human-readable snapshot of the live bank. One exam, one flat
  list: no exam-track or other area partitioning.

      mix nurseprep.export_questions
      mix nurseprep.export_questions --path priv/source_data/questions_export.json
      mix nurseprep.export_questions --status published
  """
  use Mix.Task

  alias NursePrep.Questions.Export

  @default_path "priv/source_data/questions_export.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [path: :string, status: :string])

    path = opts[:path] || @default_path
    filters = if opts[:status], do: %{status: opts[:status]}, else: %{}

    count = Export.write!(path, filters)

    Mix.shell().info("Wrote #{count} question(s) to #{path}")
  end
end
