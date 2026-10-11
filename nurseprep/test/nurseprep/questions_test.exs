defmodule NursePrep.QuestionsTest do
  use NursePrep.DataCase, async: true

  import NursePrep.Factory
  import NursePrep.AccountsFixtures

  alias NursePrep.Questions

  describe "subjects" do
    test "create_subject/1 and list_subjects/0 round-trip" do
      {:ok, subject} =
        Questions.create_subject(%{"name" => "Pharmacology", "slug" => "pharmacology"})

      assert Questions.get_subject_by_slug("pharmacology").id == subject.id
      assert Enum.any?(Questions.list_subjects(), &(&1.id == subject.id))
    end

    test "create_subject/1 enforces unique slug" do
      insert(:subject, slug: "dup")
      assert {:error, changeset} = Questions.create_subject(%{"name" => "Other", "slug" => "dup"})
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "seed_canonical_subjects/0 creates all eight NMCN subjects and is safe to re-run" do
      Questions.seed_canonical_subjects()
      assert length(Questions.list_subjects()) == 8
      assert Questions.get_subject_by_slug("pharmacology")

      Questions.seed_canonical_subjects()
      assert length(Questions.list_subjects()) == 8
    end
  end

  describe "questions" do
    test "create_question/2 inserts a question with ordered options" do
      subject = insert(:subject)

      {:ok, question} =
        Questions.create_question(
          %{
            "subject_id" => subject.id,
            "stem" => "What is the hallmark of Primary Health Care?",
            "question_type" => "mcq",
            "status" => "draft"
          },
          [
            %{label: "A", body: "Community mobilization", is_correct: false},
            %{label: "B", body: "Community participation", is_correct: true},
            %{label: "C", body: "Self reliance", is_correct: false},
            %{label: "D", body: "Community motivation", is_correct: false}
          ]
        )

      assert length(question.options) == 4
      assert Enum.find(question.options, & &1.is_correct).label == "B"
    end

    test "list_questions/1 filters by status and subject" do
      subject = insert(:subject)
      insert(:question, subject: subject, status: "published")
      insert(:question, subject: subject, status: "draft")
      other_subject_question = insert(:question, status: "published")

      results = Questions.list_questions(%{status: "published", subject_id: subject.id})

      assert length(results) == 1
      refute Enum.any?(results, &(&1.id == other_subject_question.id))
    end

    test "random_question_set/1 draws from a single flat pool of published questions" do
      first = insert_question_with_options(status: "published")
      second = insert_question_with_options(status: "published")
      insert_question_with_options(status: "draft")

      results = Questions.random_question_set(limit: 10)
      ids = Enum.map(results, & &1.id)

      assert first.id in ids
      assert second.id in ids
      assert Enum.all?(results, &(&1.status == "published"))
    end

    test "random_question_set/1 excludes published mcq questions with no option marked correct" do
      good = insert_question_with_options(status: "published")
      broken = insert(:question, status: "published")
      insert(:option, question: broken, label: "A", position: 1, is_correct: false)
      insert(:option, question: broken, label: "B", position: 2, is_correct: false)

      results = Questions.random_question_set(limit: 10)

      ids = Enum.map(results, & &1.id)
      assert good.id in ids
      refute broken.id in ids
    end
  end

  describe "review queue" do
    test "approve_review/3 publishes the question once its last pending review clears" do
      question = insert_question_with_options(status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, _} = Questions.approve_review(review, nil)

      assert Questions.get_question!(question.id).status == "published"
    end

    test "approve_review/3 refuses to approve an mcq question with no option marked correct" do
      question = insert(:question, status: "pending_review")
      insert(:option, question: question, label: "A", position: 1, is_correct: false)
      insert(:option, question: question, label: "B", position: 2, is_correct: false)

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "flagged_malformed"
        })

      assert {:error, :no_correct_option} = Questions.approve_review(review, nil)
      assert Questions.get_question!(question.id).status == "pending_review"

      assert Questions.get_question!(question.id).question_reviews |> hd() |> Map.get(:status) ==
               "pending"
    end

    test "reject_review/3 records reviewer notes without publishing" do
      question = insert(:question, status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "flagged_malformed"
        })

      {:ok, rejected} = Questions.reject_review(review, nil, "Options don't match the stem")

      assert rejected.status == "rejected"
      assert Questions.get_question!(question.id).status == "pending_review"
    end

    test "list_ai_cleanup_candidates/1 returns only pending ingestion_cleanup reviews with no suggestion yet" do
      question1 = insert(:question, status: "pending_review")
      question2 = insert(:question, status: "pending_review")
      question3 = insert(:question, status: "pending_review")

      {:ok, candidate} =
        Questions.create_review(%{
          "question_id" => question1.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, already_suggested} =
        Questions.create_review(%{
          "question_id" => question2.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, _} =
        Questions.store_ai_suggestion(already_suggested, %{"ai_suggested_stem" => "done"})

      {:ok, _wrong_type} =
        Questions.create_review(%{
          "question_id" => question3.id,
          "review_type" => "flagged_malformed"
        })

      candidates = Questions.list_ai_cleanup_candidates(25)

      assert Enum.map(candidates, & &1.id) == [candidate.id]
    end

    test "list_ai_cleanup_candidates/1 respects the limit" do
      for _ <- 1..3 do
        question = insert(:question, status: "pending_review")

        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })
      end

      assert length(Questions.list_ai_cleanup_candidates(2)) == 2
    end

    test "taxonomy_for_prompt/0 lists every topic under its subject" do
      subject = insert(:subject, name: "Pharmacology")
      insert(:topic, subject: subject, name: "Drug Interactions")

      assert Questions.taxonomy_for_prompt() =~ "Pharmacology > Drug Interactions"
    end

    test "store_ai_suggestion/2 writes the suggestion without touching the live question" do
      question = insert(:question, status: "pending_review", stem: "Original stem")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, updated_review} =
        Questions.store_ai_suggestion(review, %{
          "ai_suggested_stem" => "Cleaned stem",
          "ai_confidence" => 0.9
        })

      assert updated_review.ai_suggested_stem == "Cleaned stem"
      assert Questions.get_question!(question.id).stem == "Original stem"
    end

    test "accept_ai_suggestion/2 applies the suggestion to the question and approves the review" do
      subject = insert(:subject)
      topic = insert(:topic, subject: subject)
      question = insert_question_with_options(status: "pending_review", stem: "Raw stem")

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, review} =
        Questions.store_ai_suggestion(review, %{
          "ai_suggested_stem" => "Clean stem",
          "ai_suggested_subject_id" => subject.id,
          "ai_suggested_topic_id" => topic.id,
          "ai_confidence" => 0.9
        })

      {:ok, _} = Questions.accept_ai_suggestion(review, nil)

      updated_question = Questions.get_question!(question.id)
      assert updated_question.stem == "Clean stem"
      assert updated_question.subject_id == subject.id
      assert updated_question.topic_id == topic.id
      assert updated_question.status == "published"

      assert NursePrep.Repo.get!(NursePrep.Questions.QuestionReview, review.id).status ==
               "approved"
    end

    test "accept_ai_suggestion/2 refuses and rolls back for an mcq question with no correct option" do
      question = insert(:question, status: "pending_review", stem: "Raw stem")
      insert(:option, question: question, label: "A", position: 1, is_correct: false)
      insert(:option, question: question, label: "B", position: 2, is_correct: false)

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "ingestion_cleanup"
        })

      {:ok, review} =
        Questions.store_ai_suggestion(review, %{"ai_suggested_stem" => "Clean stem"})

      assert {:error, :no_correct_option} = Questions.accept_ai_suggestion(review, nil)

      assert Questions.get_question!(question.id).stem == "Raw stem"

      assert NursePrep.Repo.get!(NursePrep.Questions.QuestionReview, review.id).status ==
               "pending"
    end
  end

  describe "pending_reviews_by_type/0" do
    test "counts only pending reviews, grouped by type, omitting zero-count types" do
      q1 = insert(:question, status: "pending_review")
      q2 = insert(:question, status: "pending_review")
      q3 = insert_question_with_options(status: "pending_review")

      {:ok, _} =
        Questions.create_review(%{"question_id" => q1.id, "review_type" => "ingestion_cleanup"})

      {:ok, _} =
        Questions.create_review(%{"question_id" => q2.id, "review_type" => "ingestion_cleanup"})

      {:ok, tagging_review} =
        Questions.create_review(%{"question_id" => q3.id, "review_type" => "tagging"})

      {:ok, _} = Questions.approve_review(tagging_review, nil)

      assert Questions.pending_reviews_by_type() == [
               %{review_type: "ingestion_cleanup", count: 2}
             ]
    end

    test "returns an empty list when nothing is pending" do
      assert Questions.pending_reviews_by_type() == []
    end

    test "orders by QuestionReview.review_types/0, not by count" do
      q1 = insert(:question, status: "pending_review")
      q2 = insert(:question, status: "pending_review")

      {:ok, _} =
        Questions.create_review(%{"question_id" => q1.id, "review_type" => "flagged_malformed"})

      {:ok, _} =
        Questions.create_review(%{"question_id" => q2.id, "review_type" => "ingestion_cleanup"})

      assert Enum.map(Questions.pending_reviews_by_type(), & &1.review_type) == [
               "ingestion_cleanup",
               "flagged_malformed"
             ]
    end
  end

  describe "recent_review_decisions/1" do
    test "returns only approved/rejected reviews, newest decision first" do
      reviewer = admin_fixture()
      q1 = insert(:question, status: "pending_review")
      q2 = insert_question_with_options(status: "pending_review")
      q3 = insert(:question, status: "pending_review")

      {:ok, still_pending} =
        Questions.create_review(%{"question_id" => q1.id, "review_type" => "ingestion_cleanup"})

      {:ok, approved} =
        Questions.create_review(%{"question_id" => q2.id, "review_type" => "ingestion_cleanup"})

      {:ok, rejected} =
        Questions.create_review(%{"question_id" => q3.id, "review_type" => "flagged_malformed"})

      {:ok, approved} = Questions.approve_review(approved, reviewer.id)
      {:ok, rejected} = Questions.reject_review(rejected, reviewer.id, "bad")

      decisions = Questions.recent_review_decisions()

      assert Enum.map(decisions, & &1.id) == [rejected.id, approved.id]
      refute still_pending.id in Enum.map(decisions, & &1.id)

      decided = List.first(decisions)
      assert decided.reviewer.id == reviewer.id
      assert decided.question.id == q3.id
    end

    test "respects the limit" do
      reviewer = admin_fixture()

      for _ <- 1..3 do
        question = insert_question_with_options(status: "pending_review")

        {:ok, review} =
          Questions.create_review(%{
            "question_id" => question.id,
            "review_type" => "ingestion_cleanup"
          })

        {:ok, _} = Questions.approve_review(review, reviewer.id)
      end

      assert length(Questions.recent_review_decisions(2)) == 2
    end
  end

  describe "bulk actions" do
    test "bulk_publish/1 publishes multiple questions at once" do
      questions = insert_pair(:question, status: "draft")
      ids = Enum.map(questions, & &1.id)

      {:ok, %{published: 2, skipped: 0}} = Questions.bulk_publish(ids)

      assert Enum.all?(ids, &(Questions.get_question!(&1).status == "published"))
    end

    test "bulk_publish/1 skips questions that still have a pending review" do
      clean = insert(:question, status: "draft")
      flagged = insert(:question, status: "draft")

      {:ok, _review} =
        Questions.create_review(%{
          "question_id" => flagged.id,
          "review_type" => "flagged_malformed"
        })

      {:ok, %{published: 1, skipped: 1}} = Questions.bulk_publish([clean.id, flagged.id])

      assert Questions.get_question!(clean.id).status == "published"
      assert Questions.get_question!(flagged.id).status == "draft"
    end

    test "bulk_flag/2 flags multiple questions for manual review" do
      questions = insert_pair(:question, status: "draft")
      ids = Enum.map(questions, & &1.id)

      {:ok, 2} = Questions.bulk_flag(ids, "answer key mismatch")

      assert Enum.all?(ids, &(Questions.get_question!(&1).status == "flagged_manual_review"))
    end
  end

  describe "repair_wrongly_published_broken_questions/0" do
    test "reverts a published mcq with no correct option, leaving its pending review alone" do
      broken = insert(:question, status: "published")
      insert(:option, question: broken, label: "A", position: 1, is_correct: false)
      insert(:option, question: broken, label: "B", position: 2, is_correct: false)

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => broken.id,
          "review_type" => "flagged_malformed"
        })

      {:ok, result} = Questions.repair_wrongly_published_broken_questions()

      assert result.questions_reverted == 1
      assert result.reviews_reopened == 0
      assert result.reviews_created == 0
      assert broken.id in result.question_ids

      reverted = Questions.get_question!(broken.id)
      assert reverted.status == "flagged_manual_review"
      assert reverted.published_at == nil
      assert NursePrep.Repo.reload(review).status == "pending"
    end

    test "reopens an already-approved review on a question that slipped through with no correct option" do
      broken = insert(:question, status: "published")
      insert(:option, question: broken, label: "A", position: 1, is_correct: false)
      insert(:option, question: broken, label: "B", position: 2, is_correct: false)

      {:ok, review} =
        Questions.create_review(%{
          "question_id" => broken.id,
          "review_type" => "flagged_malformed",
          "status" => "approved"
        })

      {:ok, result} = Questions.repair_wrongly_published_broken_questions()

      assert result.reviews_reopened == 1
      assert NursePrep.Repo.reload(review).status == "pending"
      assert Questions.get_question!(broken.id).status == "flagged_manual_review"
    end

    test "creates a pending review for a broken published question that has none" do
      broken = insert(:question, status: "published")
      insert(:option, question: broken, label: "A", position: 1, is_correct: false)
      insert(:option, question: broken, label: "B", position: 2, is_correct: false)

      {:ok, result} = Questions.repair_wrongly_published_broken_questions()

      assert result.reviews_created == 1
      assert [review] = Questions.list_pending_reviews()
      assert review.question_id == broken.id
      assert review.review_type == "flagged_malformed"
    end

    test "leaves published mcq questions with a correct option untouched" do
      good = insert_question_with_options(status: "published")

      {:ok, result} = Questions.repair_wrongly_published_broken_questions()

      assert result.questions_reverted == 0
      assert Questions.get_question!(good.id).status == "published"
    end

    test "is idempotent-a second run touches nothing" do
      broken = insert(:question, status: "published")
      insert(:option, question: broken, label: "A", position: 1, is_correct: false)

      {:ok, _} = Questions.repair_wrongly_published_broken_questions()
      {:ok, result} = Questions.repair_wrongly_published_broken_questions()

      assert result.questions_reverted == 0
      assert result.reviews_reopened == 0
      assert result.reviews_created == 0
    end
  end
end
