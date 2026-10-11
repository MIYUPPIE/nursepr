defmodule Mix.Tasks.Nurseprep.ImportQuestionsJsonTest do
  use NursePrep.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Nurseprep.ImportQuestionsJson
  alias NursePrep.Questions

  # The substantive behavior (idempotency, error tolerance, dedup, the
  # unanswerable-mcq safety net) lives in `NursePrep.Questions.ImportTest`,
  # which exercises `Questions.Import.run/1` directly-the same function
  # this Mix task delegates to, and the one `NursePrep.Release` also calls
  # in production (no Mix at runtime there). These tests only check the
  # CLI wrapper's own job: arg parsing and file-existence handling.

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "import_questions_json_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "in.json")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{json_path: json_path}
  end

  test "--path is passed through to Questions.Import and questions land in the DB", %{
    json_path: json_path
  } do
    File.write!(
      json_path,
      Jason.encode!([
        %{"type" => "fill_blank", "stem" => "Wired through correctly", "options" => []}
      ])
    )

    output =
      capture_io(fn ->
        ImportQuestionsJson.run(["--path", json_path])
      end)

    assert output =~ "created:            1"
    assert [question] = Questions.list_questions(%{})
    assert question.stem == "Wired through correctly"
  end

  test "raises a clear error when the given path doesn't exist" do
    assert_raise Mix.Error, ~r/No file at/, fn ->
      capture_io(fn ->
        ImportQuestionsJson.run(["--path", "does/not/exist.json"])
      end)
    end
  end
end
