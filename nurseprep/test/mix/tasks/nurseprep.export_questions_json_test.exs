defmodule Mix.Tasks.Nurseprep.ExportQuestionsJsonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Nurseprep.ExportQuestionsJson

  @fixture_docx "test/fixtures/sample_questions.docx"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "export_questions_json_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "out.json")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{json_path: json_path}
  end

  test "converts the fixture docx into the documented JSON schema", %{json_path: json_path} do
    capture_io(fn ->
      ExportQuestionsJson.run(["--path", @fixture_docx, "--out", json_path])
    end)

    records = json_path |> File.read!() |> Jason.decode!()
    assert length(records) == 2

    mcq = Enum.find(records, &(&1["type"] == "mcq"))
    assert is_binary(mcq["stem"])
    assert mcq["section_ordinal"]
    assert mcq["number"]
    assert length(mcq["options"]) == 4
    assert Enum.count(mcq["options"], & &1["correct"]) == 1
    assert Enum.all?(mcq["options"], &Map.has_key?(&1, "label"))

    fill_blank = Enum.find(records, &(&1["type"] == "fill_blank"))
    assert fill_blank["options"] == []
  end

  test "raises a clear error when the docx path doesn't exist" do
    assert_raise Mix.Error, ~r/No file at/, fn ->
      capture_io(fn ->
        ExportQuestionsJson.run(["--path", "does/not/exist.docx"])
      end)
    end
  end
end
