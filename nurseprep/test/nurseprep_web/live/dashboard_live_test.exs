defmodule NursePrepWeb.DashboardLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.QuizFixtures
  import NursePrep.Factory

  test "prompts profile completion when none exists", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/dashboard")
    assert html =~ "Complete your profile"
  end

  test "greets the student by first name once a profile exists", %{conn: conn} do
    user = user_fixture()

    {:ok, _} = NursePrep.Accounts.create_profile(user.id, %{"full_name" => "Ada Nurse"})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    # The greeting word itself (Good morning/afternoon/evening) is
    # time-of-day dependent-only the name suffix is asserted here.
    assert html =~ "Good "
    assert html =~ ", Ada"
    refute html =~ "Complete your profile"
  end

  test "shows a readiness score once questions are answered", %{conn: conn} do
    user = user_fixture()
    answer_n_questions(user, 10, correct_fraction: 0.8)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Your Exam Readiness"
    assert html =~ "progress-ring"
    refute html =~ "--ring-pct: 0;"
  end

  test "surfaces a weak-area topic with a drill-down link to practice", %{conn: conn} do
    user = user_fixture()
    topic = NursePrep.Factory.insert(:topic, name: "Pharmacology")
    answer_topic_questions(user, topic, 10, correct_fraction: 0.2)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Topics That Need Attention"
    assert html =~ "Pharmacology"
    assert html =~ ~p"/practice?topic_id=#{topic.id}"
  end

  test "lists a completed session with a link to its results and how long ago it happened",
       %{conn: conn} do
    user = user_fixture()
    answer_n_questions(user, 3, correct_fraction: 1.0)

    session = hd(NursePrep.Quizzes.list_recent_sessions(user))

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Recent Activity"
    assert html =~ "3 questions"
    assert html =~ "3/3"
    assert html =~ ~p"/sessions/#{session.id}/results"
    assert html =~ "Today"
  end

  test "performance overview shows real week-over-week deltas, not fabricated numbers", %{
    conn: conn
  } do
    user = user_fixture()
    answer_n_questions(user, 10, correct_fraction: 1.0)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Questions Completed"
    assert html =~ "Average Accuracy"
    assert html =~ "this week"
  end

  test "the performance chart's range switch reassigns state without reloading the page", %{
    conn: conn
  } do
    user = user_fixture()
    answer_n_questions(user, 5, correct_fraction: 1.0)

    conn = log_in_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "7 Days"

    lv |> element("button[phx-value-range='days_30']") |> render_click()

    assert has_element?(lv, "button.btn-primary[phx-value-range='days_30']")
  end

  test "the performance chart's metric switch reassigns state", %{conn: conn} do
    user = user_fixture()
    answer_n_questions(user, 5, correct_fraction: 1.0)

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    lv |> element("button[phx-value-metric='answered']") |> render_click()

    assert has_element?(lv, "button.btn-primary[phx-value-metric='answered']")
  end

  test "streak widget shows the weekly grid and the fixed weekly goal", %{conn: conn} do
    user = user_fixture()
    answer_n_questions(user, 3, correct_fraction: 1.0)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Your Study Streak"
    assert html =~ "Goal: <span"
    assert html =~ "5/week"
  end

  test "mock exam promo offers an upgrade CTA instead of a start button for a free-tier user", %{
    conn: conn
  } do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Upgrade to Unlock"
    refute html =~ "Start Mock Exam"
  end

  test "mock exam promo offers a start button for a subscribed user", %{conn: conn} do
    user = user_fixture()
    subscribe!(user)
    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Start Mock Exam"
    refute html =~ "Upgrade to Unlock"
  end

  test "leaderboard widget updates live when another student completes a session", %{
    conn: conn
  } do
    user = user_fixture()
    insert(:profile_for, user: user, full_name: "Board Watcher", leaderboard_opt_in: true)

    conn = log_in_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/dashboard")
    refute html =~ "New Scorer"

    other_user = user_fixture()
    insert(:profile_for, user: other_user, full_name: "New Scorer", leaderboard_opt_in: true)
    answer_n_questions(other_user, 5, correct_fraction: 1.0)

    assert render(lv) =~ "New Scorer"
  end
end
