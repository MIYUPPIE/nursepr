defmodule NursePrep.Questions.ExportTest do
  use NursePrep.DataCase, async: true

  import NursePrep.Factory

  alias NursePrep.Questions
  alias NursePrep.Questions.Export

  describe "to_list/1" do
    test "serializes a question with subject, topic, options, and explanation" do
      subject = insert(:subject, name: "Pharmacology")
      topic = insert(:topic, subject: subject, name: "Antibiotics")

      question =
        insert(:question,
          subject: subject,
          topic: topic,
          status: "published",
          source_section_ordinal: 3,
          source_section_label: "SECTION C",
          source_question_number: 7
        )

      insert(:option,
        question: question,
        label: "A",
        body: "Penicillin",
        is_correct: true,
        position: 1
      )

      insert(:option,
        question: question,
        label: "B",
        body: "Paracetamol",
        is_correct: false,
        position: 2
      )

      {:ok, _} =
        Questions.upsert_explanation(question.id, %{
          "body" => "Because X.",
          "generated_by" => "human"
        })

      [json] = Export.to_list()

      assert json.id == question.id
      assert json.status == "published"
      assert json.subject == "Pharmacology"
      assert json.topic == "Antibiotics"
      assert json.source == %{section_ordinal: 3, section_label: "SECTION C", question_number: 7}
      assert json.explanation == "Because X."

      assert json.options == [
               %{label: "A", body: "Penicillin", is_correct: true},
               %{label: "B", body: "Paracetamol", is_correct: false}
             ]

      refute Map.has_key?(json, :exam_track)
    end

    test "handles a question with no subject, topic, or explanation" do
      question = insert(:question, subject: nil, topic: nil)

      [json] = Export.to_list()

      assert json.id == question.id
      assert json.subject == nil
      assert json.topic == nil
      assert json.explanation == nil
      assert json.options == []
    end

    test "filters by status" do
      published = insert(:question, status: "published")
      insert(:question, status: "draft")

      [json] = Export.to_list(%{status: "published"})
      assert json.id == published.id
    end

    test "orders by id" do
      third = insert(:question)
      first = insert(:question)
      second = insert(:question)

      ids = Export.to_list() |> Enum.map(& &1.id)
      assert ids == Enum.sort([first.id, second.id, third.id])
    end
  end

  describe "write!/2" do
    test "writes valid, round-trippable JSON to the given path" do
      insert(:question, stem: "What is the hallmark of PHC?")

      tmp_dir = Path.join(System.tmp_dir!(), "export_test_#{System.unique_integer([:positive])}")
      path = Path.join([tmp_dir, "nested", "questions_export.json"])
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert Export.write!(path) == 1
      assert File.exists?(path)

      [decoded] = path |> File.read!() |> Jason.decode!()
      assert decoded["stem"] == "What is the hallmark of PHC?"
    end
  end
end
