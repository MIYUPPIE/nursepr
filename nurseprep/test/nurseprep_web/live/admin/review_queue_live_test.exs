defmodule NursePrepWeb.Admin.ReviewQueueLiveTest do
  use NursePrepWeb.ConnCase, async: true
  use Oban.Testing, repo: NursePrep.Repo

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  alias NursePrep.Questions.Workers.AiCleanupWorker

  setup :register_admin

  test "shows nothing pending when the queue is empty", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/admin/review-queue")
    assert html =~ "Nothing pending"
  end

  test "approving the only review publishes the question and empties the queue", %{conn: conn} do
    question = insert_question_with_options(status: "pending_review")

    {:ok, _review} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, lv, html} = live(conn, ~p"/admin/review-queue")
    assert html =~ question.stem

    html = lv |> element("button", "Approve") |> render_click()
    assert html =~ "Nothing pending"
    assert NursePrep.Questions.get_question!(question.id).status == "published"
  end

  test "approving a flagged question with no correct option shows an error and stays pending",
       %{conn: conn} do
    question = insert(:question, status: "pending_review")
    insert(:option, question: question, label: "A", position: 1, is_correct: false)
    insert(:option, question: question, label: "B", position: 2, is_correct: false)

    {:ok, review} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "flagged_malformed"
      })

    {:ok, lv, _html} = live(conn, ~p"/admin/review-queue")

    html = lv |> element("button", "Approve") |> render_click()

    assert html =~ "Can&#39;t approve"
    assert NursePrep.Questions.get_question!(question.id).status == "pending_review"
    assert NursePrep.Repo.reload(review).status == "pending"
  end

  test "keyboard shortcut 'a' approves the current review", %{conn: conn} do
    question = insert_question_with_options(status: "pending_review")

    {:ok, _review} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, lv, _html} = live(conn, ~p"/admin/review-queue")

    lv |> element("[phx-window-keydown]") |> render_keydown(%{"key" => "a"})

    assert NursePrep.Questions.get_question!(question.id).status == "published"
  end

  test "approving the last item on the page moves to a still-current item, not an empty state", %{
    conn: conn
  } do
    q1 = insert_question_with_options(status: "pending_review", stem: "Question one")
    q2 = insert_question_with_options(status: "pending_review", stem: "Question two")

    {:ok, _} =
      NursePrep.Questions.create_review(%{
        "question_id" => q1.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, _} =
      NursePrep.Questions.create_review(%{
        "question_id" => q2.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, lv, _html} = live(conn, ~p"/admin/review-queue")

    # Move to the last (second) item, then approve it.
    lv |> element("button", "→") |> render_click()
    html = lv |> element("button", "Approve") |> render_click()

    # One item remains pending; it must still be shown, not "Nothing pending".
    refute html =~ "Nothing pending"
    assert html =~ "Question one"
  end

  test "clicking 'Suggest AI cleanup' enqueues a batch job without touching any question", %{
    conn: conn
  } do
    question = insert_question_with_options(status: "pending_review")

    {:ok, _review} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, lv, _html} = live(conn, ~p"/admin/review-queue")

    html = lv |> element("button", "Suggest AI cleanup") |> render_click()

    assert html =~ "Queued AI cleanup suggestions"
    assert_enqueued(worker: AiCleanupWorker, args: %{"limit" => 25})
    assert NursePrep.Questions.get_question!(question.id).stem == question.stem
  end

  test "shows an AI suggestion diff and accepting it publishes the cleaned question", %{
    conn: conn
  } do
    subject = insert(:subject)
    topic = insert(:topic, subject: subject)
    question = insert_question_with_options(status: "pending_review", stem: "Raw stm")

    {:ok, review} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "ingestion_cleanup"
      })

    {:ok, _} =
      NursePrep.Questions.store_ai_suggestion(review, %{
        "ai_suggested_stem" => "Raw stem",
        "ai_suggested_subject_id" => subject.id,
        "ai_suggested_topic_id" => topic.id,
        "ai_confidence" => 0.9
      })

    {:ok, lv, html} = live(conn, ~p"/admin/review-queue")
    assert html =~ "AI-suggested cleanup"
    assert html =~ "90"

    html = lv |> element("button", "Accept suggestion") |> render_click()

    assert html =~ "Nothing pending"
    updated = NursePrep.Questions.get_question!(question.id)
    assert updated.stem == "Raw stem"
    assert updated.subject_id == subject.id
    assert updated.topic_id == topic.id
    assert updated.status == "published"
  end

  test "a ?type= param deep-links straight into that filter", %{conn: conn} do
    tagging_question = insert_question_with_options(status: "pending_review", stem: "Tagging one")
    malformed_question = insert(:question, status: "pending_review", stem: "Malformed one")
    insert(:option, question: malformed_question, label: "A", position: 1, is_correct: false)

    {:ok, _} =
      NursePrep.Questions.create_review(%{
        "question_id" => tagging_question.id,
        "review_type" => "tagging"
      })

    {:ok, _} =
      NursePrep.Questions.create_review(%{
        "question_id" => malformed_question.id,
        "review_type" => "flagged_malformed"
      })

    {:ok, _lv, html} = live(conn, ~p"/admin/review-queue?type=flagged_malformed")

    assert html =~ "Malformed one"
    refute html =~ "Tagging one"
  end

  test "an unrecognized ?type= value falls back to unfiltered instead of hiding everything", %{
    conn: conn
  } do
    question = insert_question_with_options(status: "pending_review")

    {:ok, _} =
      NursePrep.Questions.create_review(%{
        "question_id" => question.id,
        "review_type" => "tagging"
      })

    {:ok, _lv, html} = live(conn, ~p"/admin/review-queue?type=not_a_real_type")

    assert html =~ question.stem
  end

  defp register_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end
end
