defmodule Mix.Tasks.Nurseprep.ImportQuestionsJson do
  @shortdoc "Loads a question JSON file straight into the DB as published — no draft/review step"

  @moduledoc """
  Dev-time CLI wrapper around `NursePrep.Questions.Import.run/1` — see that
  module for the schema, idempotency, and error-handling contract.

      mix nurseprep.import_questions_json --path priv/source_data/nursing_questions.json

  In production (no Mix at runtime), run the same logic via
  `NursePrep.Release.import_questions_json/1` (`bin/nurseprep eval`).
  """
  use Mix.Task

  alias NursePrep.Questions.Import

  @default_path "priv/source_data/nursing_questions.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [path: :string])
    json_path = opts[:path] || @default_path

    unless File.exists?(json_path) do
      Mix.raise("No file at #{json_path}. Pass --path or place the file at #{@default_path}.")
    end

    Mix.shell().info("Importing questions from #{json_path}...")

    result = Import.run(json_path)

    Mix.shell().info("""

    Imported:
      created:            #{result.created}
      skipped (existing):  #{result.skipped_existing}
      errored (skipped):   #{result.errored}
    """)
  end
end
