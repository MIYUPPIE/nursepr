defmodule NursePrep.Questions.IngestionTest do
  use NursePrep.DataCase, async: false

  alias NursePrep.Questions
  alias NursePrep.Questions.Ingestion

  @fixture_docx "test/fixtures/sample_questions.docx"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ingestion_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "source.json")

    {_output, 0} =
      System.cmd("pandoc", [
        @fixture_docx,
        "-t",
        "json",
        "--extract-media=#{tmp_dir}/media",
        "-o",
        json_path
      ])

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{json_path: json_path}
  end

  test "ingests a clean MCQ question as draft with a pending review", %{json_path: json_path} do
    result = Ingestion.run(json_path)

    assert result.persisted.created == 2

    mcq_summary = Questions.list_questions(%{}) |> Enum.find(&(&1.question_type == "mcq"))
    mcq = Questions.get_question!(mcq_summary.id)

    assert mcq.status == "draft"
    assert length(mcq.options) == 4
    assert Enum.find(mcq.options, & &1.is_correct).label == "B"
    assert [%{status: "pending", review_type: "ingestion_cleanup"}] = mcq.question_reviews

    fill_blank = Questions.list_questions(%{}) |> Enum.find(&(&1.question_type == "fill_blank"))
    assert fill_blank.status == "draft"
    assert fill_blank.options == []
  end

  test "is idempotent-re-running the same file creates nothing new", %{json_path: json_path} do
    first = Ingestion.run(json_path)
    assert first.persisted.created == 2

    second = Ingestion.run(json_path)
    assert second.persisted.created == 0
    assert second.persisted.skipped_existing == 2

    assert length(Questions.list_questions(%{})) == 2
  end

  test "broadcasts progress over PubSub when a topic is given", %{json_path: json_path} do
    Phoenix.PubSub.subscribe(NursePrep.PubSub, "ingestion:test")

    Ingestion.run(json_path, pubsub_topic: "ingestion:test")

    assert_receive {:ingestion_progress, 1, 2}
    assert_receive {:ingestion_progress, 2, 2}
  end

  # Regression test for a real crash hit while ingesting the production
  # docx: a question with no nested options followed by *two* consecutive
  # top-level LowerAlpha lists (the fallback path for broken Word nesting)
  # both attach as that question's options, producing duplicate labels
  # (A,B,C,D,A,B). Inserting those violates the (question_id, label) unique
  # index-and because that happens inside the question's own transaction,
  # Postgres aborts the transaction, which makes every *subsequent* insert
  # in it fail with an unrelated-looking 25P02 error that isn't recognized
  # as a constraint violation and gets re-raised, crashing the whole run.
  # This must flag the one question, not take down the other 4,999.
  test "flags a question with duplicate-labeled options instead of crashing the run" do
    blocks = [
      %{"t" => "Para", "c" => words("SECTION A: OBJECTIVEQUESTIONS")},
      %{
        "t" => "OrderedList",
        "c" => [
          [1, %{"t" => "Decimal"}, %{"t" => "Period"}],
          [[%{"t" => "Para", "c" => words("A question whose options got merged")}]]
        ]
      },
      %{
        "t" => "OrderedList",
        "c" => [
          [1, %{"t" => "LowerAlpha"}, %{"t" => "Period"}],
          [
            [%{"t" => "Para", "c" => words("Option one")}],
            [%{"t" => "Para", "c" => words("Option two")}],
            [%{"t" => "Para", "c" => words("Option three")}],
            [%{"t" => "Para", "c" => words("Option four")}]
          ]
        ]
      },
      %{
        "t" => "OrderedList",
        "c" => [
          [1, %{"t" => "LowerAlpha"}, %{"t" => "Period"}],
          [
            [%{"t" => "Para", "c" => words("Duplicate option one")}],
            [%{"t" => "Para", "c" => words("Duplicate option two")}]
          ]
        ]
      },
      %{"t" => "Para", "c" => words("SECTION A: OBJECTIVE ANSWERS")}
    ]

    json_path =
      write_json_fixture(%{"pandoc-api-version" => [1, 23, 1], "meta" => %{}, "blocks" => blocks})

    result = Ingestion.run(json_path)

    assert result.persisted.flagged_malformed == 1
    assert result.persisted.created == 0

    [question_summary] = Questions.list_questions(%{})
    question = Questions.get_question!(question_summary.id)
    assert question.status == "flagged_manual_review"
    assert [%{review_type: "flagged_malformed"}] = question.question_reviews
    # Deduped to the first-seen 4 (A-D); the duplicate A/B from the second
    # merged-in list were dropped rather than crashing the insert.
    assert Enum.map(question.options, & &1.label) |> Enum.sort() == ["A", "B", "C", "D"]
  end

  defp words(text) do
    text
    |> String.split(" ")
    |> Enum.map(&%{"t" => "Str", "c" => &1})
    |> Enum.intersperse(%{"t" => "Space"})
  end

  defp write_json_fixture(data) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ingestion_test_json_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "source.json")
    File.write!(path, Jason.encode!(data))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    path
  end
end
