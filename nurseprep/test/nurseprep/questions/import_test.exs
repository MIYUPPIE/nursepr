defmodule NursePrep.Questions.ImportTest do
  use NursePrep.DataCase, async: false

  alias NursePrep.Questions
  alias NursePrep.Questions.Import

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "import_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "in.json")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{json_path: json_path}
  end

  defp write_fixture(json_path, records), do: File.write!(json_path, Jason.encode!(records))

  test "imports an mcq straight to published with its options, skipping review entirely", %{
    json_path: json_path
  } do
    write_fixture(json_path, [
      %{
        "section" => "SECTION A: OBJECTIVE QUESTIONS",
        "section_ordinal" => 1,
        "number" => 1,
        "type" => "mcq",
        "stem" => "What is the normal adult heart rate range?",
        "has_image" => false,
        "options" => [
          %{"label" => "A", "body" => "40-60 bpm", "correct" => false},
          %{"label" => "B", "body" => "60-100 bpm", "correct" => true},
          %{"label" => "C", "body" => "100-140 bpm", "correct" => false},
          %{"label" => "D", "body" => "140-180 bpm", "correct" => false}
        ]
      }
    ])

    assert %{created: 1, skipped_existing: 0, errored: 0} = Import.run(json_path)

    [question] = Questions.list_questions(%{})
    question = Questions.get_question!(question.id)

    assert question.status == "published"
    assert question.published_at
    assert question.question_reviews == []
    assert length(question.options) == 4
    assert Enum.find(question.options, & &1.is_correct).label == "B"
  end

  test "imports a fill_blank question with no options", %{json_path: json_path} do
    write_fixture(json_path, [
      %{
        "type" => "fill_blank",
        "stem" => "The milk secreting cells are known as ___________",
        "options" => []
      }
    ])

    Import.run(json_path)

    [question] = Questions.list_questions(%{})
    question = Questions.get_question!(question.id)
    assert question.status == "published"
    assert question.options == []
  end

  test "is idempotent for records with section_ordinal + number: re-running creates nothing new",
       %{json_path: json_path} do
    write_fixture(json_path, [
      %{
        "section_ordinal" => 1,
        "number" => 1,
        "type" => "mcq",
        "stem" => "Q1",
        "options" => [
          %{"label" => "A", "body" => "a", "correct" => true},
          %{"label" => "B", "body" => "b", "correct" => false}
        ]
      }
    ])

    assert %{created: 1} = Import.run(json_path)
    assert %{created: 0, skipped_existing: 1} = Import.run(json_path)
    assert length(Questions.list_questions(%{})) == 1
  end

  test "records with no section_ordinal/number always insert fresh (no dedup key)", %{
    json_path: json_path
  } do
    write_fixture(json_path, [
      %{"type" => "fill_blank", "stem" => "Hand-authored question", "options" => []}
    ])

    Import.run(json_path)
    Import.run(json_path)

    assert length(Questions.list_questions(%{})) == 2
  end

  test "a malformed record is skipped without aborting the rest of the batch", %{
    json_path: json_path
  } do
    write_fixture(json_path, [
      %{"type" => "mcq", "stem" => "Good question", "options" => []},
      %{"type" => "not_a_real_type", "stem" => "Bad record"},
      %{"stem" => "Missing type entirely"}
    ])

    assert %{created: 1, errored: 2} = Import.run(json_path)
    assert [question] = Questions.list_questions(%{})
    assert question.stem == "Good question"
  end

  test "duplicate option labels within one record are deduped (first wins) instead of erroring",
       %{json_path: json_path} do
    write_fixture(json_path, [
      %{
        "type" => "mcq",
        "stem" => "Q with dup labels",
        "options" => [
          %{"label" => "A", "body" => "first A", "correct" => true},
          %{"label" => "A", "body" => "duplicate A", "correct" => false},
          %{"label" => "B", "body" => "b", "correct" => false}
        ]
      }
    ])

    Import.run(json_path)

    [question] = Questions.list_questions(%{})
    question = Questions.get_question!(question.id)
    assert length(question.options) == 2
    assert Enum.find(question.options, &(&1.label == "A")).body == "first A"
  end

  test "an unanswerable mcq (no correct option) imports but is never served to students", %{
    json_path: json_path
  } do
    write_fixture(json_path, [
      %{
        "type" => "mcq",
        "stem" => "No answer marked",
        "options" => [
          %{"label" => "A", "body" => "a", "correct" => false},
          %{"label" => "B", "body" => "b", "correct" => false}
        ]
      }
    ])

    Import.run(json_path)

    [question] = Questions.list_questions(%{})
    assert question.status == "published"
    assert Questions.random_question_set(limit: 10) == []
  end

  test "raises when the file isn't a JSON array", %{json_path: json_path} do
    File.write!(json_path, Jason.encode!(%{"not" => "an array"}))
    assert_raise ArgumentError, fn -> Import.run(json_path) end
  end
end
