defmodule NursePrep.Questions.Ingestion.DocxParserTest do
  use ExUnit.Case, async: true

  alias NursePrep.Questions.Ingestion.DocxParser

  # Block/inline builders mirror pandoc's JSON AST shape exactly (verified
  # directly against `pandoc source.docx -t json` output on the real source
  # file during development) so these tests exercise the real decode path,
  # not an imagined simplification of it.
  defp str(s), do: %{"t" => "Str", "c" => s}
  defp space, do: %{"t" => "Space"}
  defp para(text), do: %{"t" => "Para", "c" => words(text)}
  defp plain(text), do: %{"t" => "Plain", "c" => words(text)}

  defp words(text) do
    text
    |> String.split(" ")
    |> Enum.map(&str/1)
    |> Enum.intersperse(space())
  end

  defp image_para(text, path) do
    %{
      "t" => "Para",
      "c" => [%{"t" => "Image", "c" => [["", [], []], [], [path, ""]]} | words(text)]
    }
  end

  defp ordered_list(start, style, items),
    do: %{"t" => "OrderedList", "c" => [[start, %{"t" => style}, %{"t" => "Period"}], items]}

  defp track_title(text), do: para(text)

  defp cell(blocks), do: [["", [], []], %{"t" => "AlignDefault"}, 1, 1, blocks]
  defp row(cells), do: [["", [], []], cells]

  defp answer_table(pairs) do
    rows =
      Enum.map(pairs, fn {number, letter} ->
        row([
          cell([ordered_list(number, "Decimal", [[]])]),
          cell([plain(letter)])
        ])
      end)

    %{
      "t" => "Table",
      "c" => [
        ["", [], []],
        [nil, []],
        [[%{"t" => "AlignDefault"}, %{"t" => "ColWidth", "c" => 0.5}]],
        [["", [], []], []],
        [[["", [], []], 0, [], rows]],
        [["", [], []], []]
      ]
    }
  end

  test "parses a clean MCQ question with nested lettered options" do
    blocks = [
      track_title("OBJECTIVE QUESTIONS AND ANSWERS FOR GENERAL NURSES"),
      para("SECTION A: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [
        [
          para("The hallmark of Primary Health Care is"),
          ordered_list(1, "LowerAlpha", [
            [para("Community mobilization")],
            [para("Community participation")],
            [para("Self reliance")],
            [para("Community motivation")]
          ])
        ]
      ]),
      para("SECTION A: OBJECTIVE ANSWERS"),
      answer_table([{1, "B"}])
    ]

    {[question], [], summary} = DocxParser.parse_blocks(blocks)

    assert question.question_number == 1
    assert question.stem == "The hallmark of Primary Health Care is"
    assert question.question_type == :mcq
    assert question.answer_label == "B"
    assert question.has_image == false

    assert Enum.map(question.options, & &1.label) == ["A", "B", "C", "D"]
    assert Enum.at(question.options, 1).text == "Community participation"

    assert summary.total_questions == 1
    assert summary.mcq == 1
    assert summary.missing_answer == 0
  end

  test "pairs the Nth questions-header with the Nth answers-header even across a split header" do
    # Reproduces the real source's "SECTION C: OBJECTIVE" / "ANSWERS" split
    # across two separate Para blocks, and a section-label typo
    # ("SECTIODN D;")-both must still resolve to correct answer pairing.
    blocks = [
      para("SECTION A: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [[para("Question one")]]),
      para("SECTION A: OBJECTIVE ANSWERS"),
      answer_table([{1, "A"}]),
      para("SECTIODN D; OBJECTIVES"),
      ordered_list(1, "Decimal", [[para("Question two")]]),
      para("SECTION D: OBJECTIVE ANSWERS"),
      answer_table([{1, "C"}])
    ]

    {questions, _notes, summary} = DocxParser.parse_blocks(blocks)

    assert summary.total_sections == 2
    assert Enum.find(questions, &(&1.stem == "Question one")).answer_label == "A"
    assert Enum.find(questions, &(&1.stem == "Question two")).answer_label == "C"
  end

  test "handles the split header case: 'SECTION C: OBJECTIVE' then bare 'ANSWERS' on the next block" do
    blocks = [
      para("SECTION C: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [[para("Only question")]]),
      para("SECTION C: OBJECTIVE"),
      para("ANSWERS"),
      answer_table([{1, "D"}])
    ]

    {[question], _notes, summary} = DocxParser.parse_blocks(blocks)

    assert summary.total_sections == 1
    assert question.answer_label == "D"
  end

  test "falls back to a top-level LowerAlpha list when options aren't nested under the question item" do
    blocks = [
      para("SECTION B: OBJECTIVE QUESTIONS"),
      ordered_list(14, "Decimal", [[para("A condition associated with repeated drug use is")]]),
      ordered_list(1, "LowerAlpha", [
        [para("Drug repetition")],
        [para("Drug dependence")],
        [para("Drug reliance")],
        [para("Drug hazards")]
      ]),
      para("SECTION B: OBJECTIVE ANSWERS"),
      answer_table([{14, "B"}])
    ]

    {[question], _notes, _summary} = DocxParser.parse_blocks(blocks)

    assert length(question.options) == 4
    assert Enum.at(question.options, 1).text == "Drug dependence"
    assert question.answer_label == "B"
  end

  test "falls back to plain paragraphs with a typed (a) prefix as options" do
    blocks = [
      para("SECTION B: OBJECTIVE QUESTIONS"),
      ordered_list(1, "Decimal", [[para("Coping mechanisms include")]]),
      para("(a) Problem-focused coping mechanism."),
      para("(b) Cognitive-focused coping mechanism."),
      para("SECTION B: OBJECTIVE ANSWERS"),
      answer_table([{1, "A"}])
    ]

    {[question], _notes, _summary} = DocxParser.parse_blocks(blocks)

    assert Enum.map(question.options, & &1.label) == ["A", "B"]
    assert question.question_type == :mcq
  end

  test "classifies a zero-option question with blank markers as fill_blank" do
    blocks = [
      para("SECTION E OBJECTIVE QUESTIONS"),
      ordered_list(1, "Decimal", [
        [
          para(
            "Nerves communicate with each other by releasing............... into tiny gaps between them."
          )
        ]
      ]),
      para("SECTION E: OBJECTIVE ANSWERS"),
      answer_table([])
    ]

    {[question], _notes, summary} = DocxParser.parse_blocks(blocks)

    assert question.question_type == :fill_blank
    assert question.answer_label == nil
    assert summary.fill_blank == 1
    assert summary.missing_answer == 1
  end

  test "flags a diagram-referencing question and records an image note" do
    blocks = [
      para("SECTION D: OBJECTIVE QUESTIONS"),
      ordered_list(10, "Decimal", [[para("Questions 10 to 12 refer to the diagram below")]]),
      para("Label the diagram below"),
      image_para("", "media/image1.jpeg"),
      para("SECTION D: OBJECTIVE ANSWERS"),
      answer_table([])
    ]

    {[question], notes, summary} = DocxParser.parse_blocks(blocks)

    assert question.has_image == true
    assert question.image_refs == ["media/image1.jpeg"]
    assert summary.with_image == 1
    assert length(notes) == 1
    assert hd(notes).image_paths == ["media/image1.jpeg"]
  end

  test "recovers answers from a list-based answer key (second source track's format)" do
    # The second track's answer key isn't a Table at all: each question's
    # answer is a single-item decimal OrderedList starting at that question
    # number, mixed with bare letters and letter-plus-text-reproduces
    # the real structure found in the production docx.
    blocks = [
      para("SECTION A: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [
        [para("First question")],
        [para("Second question")],
        [para("Third question")]
      ]),
      para("SECTION A: OBJECTIVE ANSWERS"),
      ordered_list(1, "Decimal", [[para("B")]]),
      ordered_list(2, "Decimal", [[para("D")]]),
      ordered_list(3, "Decimal", [[para("A. lobules")]])
    ]

    {questions, _notes, _summary} = DocxParser.parse_blocks(blocks)

    answers = Map.new(questions, &{&1.question_number, &1.answer_label})
    assert answers == %{1 => "B", 2 => "D", 3 => "A"}
  end

  test "leaves free-text list-based answers (no option letter) unresolved rather than guessing" do
    blocks = [
      para("SECTION A: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [[para("Diagram part one")]]),
      para("SECTION A: OBJECTIVE ANSWERS"),
      # Neither "Cortex/Medulla" nor "FALSE PELVIS" starts with a bare
      # option letter-must not be misread as answer "C" or "F".
      ordered_list(1, "Decimal", [[para("Cortex/Medulla")]])
    ]

    {[question], _notes, _summary} = DocxParser.parse_blocks(blocks)

    assert question.answer_label == nil
  end

  test "handles a list-based answer key with interleaved stray paragraphs and mixed resolvable/unresolvable items" do
    blocks = [
      para("SECTION A: OBJECTIVEQUESTIONS"),
      ordered_list(1, "Decimal", [
        [para("Q1")],
        [para("Q2")],
        [para("Q3")]
      ]),
      para("SECTION A: OBJECTIVE ANSWERS"),
      ordered_list(1, "Decimal", [[para("B")], [para("PUBLIC BONE")]]),
      para("stray leftover text, not an answer"),
      ordered_list(3, "Decimal", [[para("D")]])
    ]

    {questions, _notes, summary} = DocxParser.parse_blocks(blocks)

    answers = Map.new(questions, &{&1.question_number, &1.answer_label})
    assert answers == %{1 => "B", 2 => nil, 3 => "D"}
    assert summary.missing_answer == 1
  end

  test "never crashes on an empty document" do
    assert {[], [], summary} = DocxParser.parse_blocks([])
    assert summary.total_questions == 0
  end
end
