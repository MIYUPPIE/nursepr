defmodule NursePrep.Questions.Ingestion.AnswerRepairTest do
  use NursePrep.DataCase, async: false

  import NursePrep.Factory

  alias NursePrep.Questions
  alias NursePrep.Questions.Ingestion.AnswerRepair

  # Builds a minimal pandoc-JSON document with one section whose answer key
  # is the list-based format (one question per `answers` entry, keyed by
  # OrderedList `start`), covering the exact shape the real production
  # docx uses for its second track. Only `answers` is varied per test;
  # `questions` just needs to exist so `finalize_question` produces an
  # entry with the section/question-number pairing under test.
  defp docx_fixture(answers) do
    words = fn text ->
      text
      |> String.split(" ")
      |> Enum.map(&%{"t" => "Str", "c" => &1})
      |> Enum.intersperse(%{"t" => "Space"})
    end

    para = fn text -> %{"t" => "Para", "c" => words.(text)} end

    question_items =
      for n <- 1..3 do
        [%{"t" => "Para", "c" => words.("Question #{n}")}]
      end

    answer_blocks =
      Enum.map(answers, fn {number, text} ->
        %{
          "t" => "OrderedList",
          "c" => [[number, %{"t" => "Decimal"}, %{"t" => "Period"}], [[para.(text)]]]
        }
      end)

    blocks =
      [
        para.("SECTION A: OBJECTIVEQUESTIONS"),
        %{
          "t" => "OrderedList",
          "c" => [[1, %{"t" => "Decimal"}, %{"t" => "Period"}], question_items]
        },
        para.("SECTION A: OBJECTIVE ANSWERS")
      ] ++ answer_blocks

    data = %{"pandoc-api-version" => [1, 23, 1], "meta" => %{}, "blocks" => blocks}

    tmp_dir =
      Path.join(System.tmp_dir!(), "answer_repair_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "source.json")
    File.write!(path, Jason.encode!(data))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    path
  end

  defp flagged_question(attrs) do
    question =
      insert(
        :question,
        Keyword.merge([status: "flagged_manual_review", question_type: "mcq"], attrs)
      )

    ["A", "B", "C", "D"]
    |> Enum.with_index(1)
    |> Enum.each(fn {label, position} ->
      insert(:option, question: question, label: label, position: position, is_correct: false)
    end)

    Questions.get_question!(question.id)
  end

  test "repairs a flagged question when the re-parse resolves a matching answer" do
    json_path = docx_fixture([{2, "C"}])

    question =
      flagged_question(
        source_section_ordinal: 1,
        source_section_label: nil,
        source_question_number: 2
      )

    review =
      Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "flagged_malformed",
        "status" => "pending"
      })

    assert {:ok, _} = review

    assert AnswerRepair.run(json_path) == %{repaired: 1, unresolved: 0}

    repaired = Questions.get_question!(question.id)
    assert repaired.status == "draft"
    assert Enum.find(repaired.options, &(&1.label == "C")).is_correct
    refute Enum.any?(repaired.options, &(&1.label != "C" and &1.is_correct))

    assert [%{status: "pending", review_type: "ingestion_cleanup"}] = repaired.question_reviews
  end

  test "leaves the question flagged when the recovered answer matches no option" do
    json_path = docx_fixture([{2, "E"}])

    question = flagged_question(source_section_ordinal: 1, source_question_number: 2)

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 1}

    unchanged = Questions.get_question!(question.id)
    assert unchanged.status == "flagged_manual_review"
    refute Enum.any?(unchanged.options, & &1.is_correct)
  end

  test "leaves the question flagged when the source still has no derivable answer" do
    json_path = docx_fixture([{2, "Cortex/Medulla"}])

    question = flagged_question(source_section_ordinal: 1, source_question_number: 2)

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 1}

    unchanged = Questions.get_question!(question.id)
    assert unchanged.status == "flagged_manual_review"
  end

  test "never touches a question that already has a correct option marked" do
    json_path = docx_fixture([{2, "B"}])

    question =
      insert(:question,
        status: "flagged_manual_review",
        question_type: "mcq",
        source_section_ordinal: 1,
        source_question_number: 2
      )

    insert(:option, question: question, label: "A", position: 1, is_correct: true)
    insert(:option, question: question, label: "B", position: 2, is_correct: false)

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 0}

    unchanged = Questions.get_question!(question.id)
    assert unchanged.status == "flagged_manual_review"
  end

  test "never touches a flagged question that references an image, even if the answer resolves" do
    json_path = docx_fixture([{2, "B"}])

    question =
      flagged_question(
        has_image: true,
        source_section_ordinal: 1,
        source_question_number: 2
      )

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 0}

    unchanged = Questions.get_question!(question.id)
    assert unchanged.status == "flagged_manual_review"
    refute Enum.any?(unchanged.options, & &1.is_correct)
  end

  test "never touches a hand-authored flagged question with no ingestion provenance" do
    json_path = docx_fixture([{2, "B"}])

    question =
      flagged_question(
        source_section_ordinal: nil,
        source_section_label: nil,
        source_question_number: nil
      )

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 0}

    unchanged = Questions.get_question!(question.id)
    assert unchanged.status == "flagged_manual_review"
  end

  test "never touches questions that aren't flagged_manual_review" do
    json_path = docx_fixture([{2, "B"}])

    published =
      insert(:question,
        status: "published",
        question_type: "mcq",
        source_section_ordinal: 1,
        source_question_number: 2
      )

    insert(:option, question: published, label: "A", position: 1, is_correct: false)
    insert(:option, question: published, label: "B", position: 2, is_correct: true)

    assert AnswerRepair.run(json_path) == %{repaired: 0, unresolved: 0}

    unchanged = Questions.get_question!(published.id)
    assert unchanged.status == "published"
  end
end
