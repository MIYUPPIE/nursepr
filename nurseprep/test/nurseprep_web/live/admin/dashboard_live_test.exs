defmodule NursePrepWeb.Admin.DashboardLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  alias NursePrep.Questions

  describe "KPI tiles" do
    test "shows question-pipeline counts to a reviewer", %{conn: conn} do
      insert(:question, status: "published")
      insert(:question, status: "draft")
      insert(:question, status: "flagged_manual_review")
      question = insert(:question, status: "pending_review")

      {:ok, _} =
        Questions.create_review(%{"question_id" => question.id, "review_type" => "tagging"})

      conn = log_in_user(conn, reviewer_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Pending reviews"
      assert html =~ "Published questions"
      assert html =~ "Draft questions"
      assert html =~ "Flagged"
    end

    test "hides student/subscription tiles from a reviewer", %{conn: conn} do
      conn = log_in_user(conn, reviewer_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      refute html =~ "Students"
      refute html =~ "Active subscriptions"
    end

    test "shows student and active-subscription tiles to a real admin", %{conn: conn} do
      user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

      insert(:subscription,
        user: user_fixture(),
        status: "active",
        current_period_end: period_end
      )

      conn = log_in_user(conn, admin_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Students"
      assert html =~ "Active subscriptions"
    end
  end

  describe "needs attention" do
    test "breaks pending reviews down by type with a deep link into the queue", %{conn: conn} do
      question = insert(:question, status: "pending_review")

      {:ok, _} =
        Questions.create_review(%{
          "question_id" => question.id,
          "review_type" => "flagged_malformed"
        })

      conn = log_in_user(conn, reviewer_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Needs attention"
      assert html =~ "flagged malformed"
      assert html =~ ~p"/admin/review-queue?type=flagged_malformed"
    end

    test "is omitted entirely when nothing is pending", %{conn: conn} do
      conn = log_in_user(conn, reviewer_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      refute html =~ "Needs attention"
    end
  end

  describe "recent activity" do
    test "shows review decisions to a reviewer but not signups or payments", %{conn: conn} do
      reviewer = reviewer_fixture()

      question =
        insert_question_with_options(status: "pending_review", stem: "A decided question")

      {:ok, review} =
        Questions.create_review(%{"question_id" => question.id, "review_type" => "tagging"})

      {:ok, _} = Questions.approve_review(review, reviewer.id)

      student = user_fixture()
      insert(:payment, user: student, status: "success", paid_at: DateTime.utc_now())

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "approved"
      assert html =~ "A decided question"
      refute html =~ "signed up"
      refute html =~ "paid"
    end

    test "shows review decisions, signups, and payments to a real admin", %{conn: conn} do
      admin = admin_fixture()
      question = insert_question_with_options(status: "pending_review")

      {:ok, review} =
        Questions.create_review(%{"question_id" => question.id, "review_type" => "tagging"})

      {:ok, _} = Questions.reject_review(review, admin.id, "no good")

      student = user_fixture()
      {:ok, _} = NursePrep.Accounts.create_profile(student.id, %{"full_name" => "Ada Nurse"})
      insert(:payment, user: student, status: "success", paid_at: DateTime.utc_now())

      conn = log_in_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "rejected"
      assert html =~ "signed up"
      assert html =~ "Ada Nurse paid"
      assert html =~ "5,000.00"
    end

    test "shows an empty state when nothing has happened yet", %{conn: conn} do
      # A reviewer, not an admin: an admin's own account creation would
      # itself show up as a "signed up" event in the same test transaction,
      # so this uses the role whose feed is scoped to review decisions only.
      conn = log_in_user(conn, reviewer_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Nothing here yet"
    end
  end

  defp reviewer_fixture do
    user = user_fixture()
    {:ok, user} = NursePrep.Accounts.promote_to_role(user, "reviewer")
    user
  end
end
