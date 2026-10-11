defmodule Mix.Tasks.Nurseprep.ExportQuestionsJson do
  @shortdoc "Converts the source exam docx into the question JSON schema (no DB writes)"

  @moduledoc """
  Converts a source docx (via pandoc + `Questions.Ingestion.DocxParser`,
  the same parser `mix nurseprep.ingest_questions` uses) into a plain JSON
  file — no database access at all. Pairs with
  `mix nurseprep.import_questions_json`, which loads that JSON straight in
  as published questions, trusting the source content as-is (no draft/
  review states).

      mix nurseprep.export_questions_json
      mix nurseprep.export_questions_json --path priv/source_data/nursing_questions.docx --out priv/source_data/nursing_questions.json

  Requires `pandoc` on PATH.

  ## JSON schema

  The output (and any hand-authored file meant for
  `mix nurseprep.import_questions_json`) is a JSON array of objects:

      {
        "section": "SECTION A: OBJECTIVE QUESTIONS",  // optional, human label
        "section_ordinal": 1,                          // optional, see below
        "number": 12,                                   // optional, see below
        "type": "mcq",                                   // "mcq" | "fill_blank" | "unresolved"
        "stem": "The question text.",
        "has_image": false,
        "options": [
          {"label": "A", "body": "First option", "correct": false},
          {"label": "B", "body": "Second option", "correct": true},
          {"label": "C", "body": "Third option", "correct": false},
          {"label": "D", "body": "Fourth option", "correct": false}
        ]
      }

  `options` is `[]` for `fill_blank`/`unresolved` questions.

  `section_ordinal` + `number` together are the dedup key (a question with
  both already present in the database is skipped on import, so re-running
  import against the same file twice is safe) — omit both on a hand-authored
  batch with no natural document position and every question just inserts
  fresh, no dedup applied.
  """
  use Mix.Task

  @default_docx_path "priv/source_data/nursing_questions.docx"
  @default_json_path "priv/source_data/nursing_questions.json"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [path: :string, out: :string])

    docx_path = opts[:path] || @default_docx_path
    json_path = opts[:out] || @default_json_path

    unless File.exists?(docx_path) do
      Mix.raise(
        "No file at #{docx_path}. Pass --path or place the docx at #{@default_docx_path}."
      )
    end

    tmp_dir =
      Path.join(System.tmp_dir!(), "nurseprep_export_#{System.unique_integer([:positive])}")

    pandoc_json_path = Path.join(tmp_dir, "source.json")
    File.mkdir_p!(tmp_dir)

    Mix.shell().info("Converting #{docx_path} via pandoc...")

    case System.cmd("pandoc", [docx_path, "-t", "json", "-o", pandoc_json_path]) do
      {_output, 0} -> :ok
      {output, _code} -> Mix.raise("pandoc failed: #{output}")
    end

    Mix.shell().info("Parsing...")
    {questions, _image_notes, summary} = parse(pandoc_json_path)

    records = Enum.map(questions, &to_export_record/1)
    File.write!(json_path, Jason.encode!(records, pretty: true))

    Mix.shell().info("""

    Parse summary: #{inspect(summary)}
    Wrote #{length(records)} questions to #{json_path}

    Run `mix nurseprep.import_questions_json --path #{json_path}` to load them.
    """)
  end

  defp parse(pandoc_json_path) do
    NursePrep.Questions.Ingestion.DocxParser.parse_file(pandoc_json_path)
  end

  defp to_export_record(q) do
    %{
      "section" => q.section_label,
      "section_ordinal" => q.section_ordinal,
      "number" => q.question_number,
      "type" => to_string(q.question_type),
      "stem" => q.stem,
      "has_image" => q.has_image,
      "options" =>
        Enum.map(q.options, fn opt ->
          %{"label" => opt.label, "body" => opt.text, "correct" => opt.label == q.answer_label}
        end)
    }
  end
end
