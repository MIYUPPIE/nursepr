defmodule NursePrep.Questions.Workers.AiCleanupWorkerTest do
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import Mox
  import NursePrep.Factory

  alias NursePrep.Questions
  alias NursePrep.Questions.Workers.AiCleanupWorker
  alias NursePrep.Questions.LocalClaudeClientMock

  setup :verify_on_exit!

  describe "fan-out (batch trigger)" do
    test "enqueues one unique job per candidate review" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      assert :ok = perform_job(AiCleanupWorker, %{"limit" => 25})

      assert_enqueued(worker: AiCleanupWorker, args: %{"review_id" => review.id})
    end

    test "does not re-enqueue a review that already has a suggestion" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, _} = Questions.store_ai_suggestion(review, %{"ai_suggested_stem" => "already done"})

      assert :ok = perform_job(AiCleanupWorker, %{"limit" => 25})

      refute_enqueued(worker: AiCleanupWorker, args: %{"review_id" => review.id})
    end

    test "ignores reviews of other types (e.g. flagged_malformed needs a human, not AI cleanup)" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "flagged_malformed"
        })

      assert :ok = perform_job(AiCleanupWorker, %{"limit" => 25})

      refute_enqueued(worker: AiCleanupWorker, args: %{"review_id" => review.id})
    end
  end

  describe "per-review suggestion" do
    test "parses the response and stores the suggestion on the review, never touching the live question" do
      topic = insert(:topic)
      question = insert(:question, status: "pending_review", raw_stem: "Wht  is nrmal BP?")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      expect(LocalClaudeClientMock, :ask, fn _prompt, _system_prompt ->
        {:ok,
         %{
           text:
             Jason.encode!(%{
               "cleaned_stem" => "What is normal BP?",
               "subject_id" => topic.subject_id,
               "topic_id" => topic.id,
               "confidence" => 0.87
             })
         }}
      end)

      assert :ok = perform_job(AiCleanupWorker, %{"review_id" => review.id})

      updated = Questions.get_question!(question.id)
      assert updated.stem == question.stem

      review = NursePrep.Repo.get!(NursePrep.Questions.QuestionReview, review.id)
      assert review.ai_suggested_stem == "What is normal BP?"
      assert review.ai_suggested_subject_id == topic.subject_id
      assert review.ai_suggested_topic_id == topic.id
      assert review.ai_confidence == 0.87
      assert review.status == "pending"
    end

    test "tolerates a response wrapped in markdown code fences" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      expect(LocalClaudeClientMock, :ask, fn _prompt, _system_prompt ->
        {:ok,
         %{
           text:
             "```json\n" <>
               Jason.encode!(%{
                 "cleaned_stem" => "Cleaned.",
                 "subject_id" => nil,
                 "topic_id" => nil,
                 "confidence" => 0.5
               }) <> "\n```"
         }}
      end)

      assert :ok = perform_job(AiCleanupWorker, %{"review_id" => review.id})

      review = NursePrep.Repo.get!(NursePrep.Questions.QuestionReview, review.id)
      assert review.ai_suggested_stem == "Cleaned."
    end

    test "returns an error tuple (for Oban to retry) on an unparseable response" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      expect(LocalClaudeClientMock, :ask, fn _prompt, _system_prompt ->
        {:ok, %{text: "not json at all"}}
      end)

      assert {:error, :unparseable_response} =
               perform_job(AiCleanupWorker, %{"review_id" => review.id})

      refute NursePrep.Repo.get!(NursePrep.Questions.QuestionReview, review.id).ai_suggested_stem
    end

    test "returns an error tuple (for Oban to retry) when the local Claude call fails" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      expect(LocalClaudeClientMock, :ask, fn _prompt, _system_prompt ->
        {:error, {:exit_status, 1, "boom"}}
      end)

      assert {:error, {:exit_status, 1, "boom"}} =
               perform_job(AiCleanupWorker, %{"review_id" => review.id})
    end
  end
end
