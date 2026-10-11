defmodule NursePrep.Questions.Ingestion.AnswerRepair do
  @moduledoc """
  One-off repair for questions that `Ingestion` flagged purely because the
  answer-key extractor of that era only understood the first source
  track's Table-based answer key-the second track's answer key is a
  different format entirely (numbered `OrderedList`s, one answer per
  question) that `DocxParser` didn't learn to read until this fix. Nothing
  about the *question* content was ever wrong; the answer was sitting
  right there in the source and simply wasn't extracted.

  Re-parses the source docx with the current `DocxParser` and, for every
  currently-flagged question that's otherwise clean (a real MCQ with no
  option already marked correct-i.e. flagged for exactly this reason
  and nothing else), applies the recovered answer the same way a clean
  first-pass ingestion would have:
  marks the matching option `is_correct`, and moves the question from
  `flagged_manual_review` into `draft` with a fresh pending
  `ingestion_cleanup` review-the normal path every cleanly-parsed
  question already goes through before an admin publishes it. Never
  touches stem, option text, or genuinely malformed/duplicate-label/image
  questions, and never guesses: a question whose recovered answer still
  doesn't match any of its captured options is left exactly as flagged as
  it was.
  """

  import Ecto.Query

  alias NursePrep.Repo
  alias NursePrep.Questions.{Question, Option, QuestionReview}
  alias NursePrep.Questions.Ingestion.DocxParser

  @doc """
  Runs the repair against a pandoc-JSON file. Returns
  `%{repaired: n, unresolved: m}`-`unresolved` covers both "the source
  still has no derivable answer for this question" and "the recovered
  answer doesn't match any of this question's captured options."
  """
  def run(json_path) do
    {parsed, _image_notes, _summary} = DocxParser.parse_file(json_path)
    answer_index = Map.new(parsed, &{{&1.section_ordinal, &1.question_number}, &1.answer_label})

    candidates()
    |> Enum.reduce(%{repaired: 0, unresolved: 0}, fn question, acc ->
      apply_repair(question, Map.get(answer_index, source_key(question)), acc)
    end)
  end

  defp source_key(question),
    do: {question.source_section_ordinal, question.source_question_number}

  # Eligible: came from ingestion, is a real MCQ, and has no option
  # currently marked correct-i.e. flagged purely for a missing/unmatched
  # answer. (Duplicate-labeled options never reach the DB in the first
  # place-`Ingestion.insert_options/3` dedupes before insert, and
  # `(question_id, label)` is a unique constraint-so that's not a
  # condition this needs to check.)
  defp candidates do
    Question
    |> where([q], q.status == "flagged_manual_review")
    |> where([q], q.question_type == "mcq")
    |> where([q], q.has_image == false)
    |> where([q], not is_nil(q.source_section_ordinal) and not is_nil(q.source_question_number))
    |> preload(:options)
    |> Repo.all()
    |> Enum.filter(&repair_eligible?/1)
  end

  defp repair_eligible?(question),
    do: question.options != [] and not Enum.any?(question.options, & &1.is_correct)

  defp apply_repair(_question, nil, acc), do: %{acc | unresolved: acc.unresolved + 1}

  defp apply_repair(question, letter, acc) do
    case Enum.find(question.options, &(&1.label == letter)) do
      nil ->
        %{acc | unresolved: acc.unresolved + 1}

      option ->
        {:ok, _} =
          Repo.transaction(fn ->
            option |> Option.changeset(%{"is_correct" => true}) |> Repo.update!()
            question |> Question.changeset(%{"status" => "draft"}) |> Repo.update!()
            reopen_review!(question)
          end)

        %{acc | repaired: acc.repaired + 1}
    end
  end

  defp reopen_review!(question) do
    from(r in QuestionReview, where: r.question_id == ^question.id and r.status == "pending")
    |> Repo.delete_all()

    Repo.insert!(%QuestionReview{
      question_id: question.id,
      review_type: "ingestion_cleanup",
      status: "pending"
    })
  end
end
