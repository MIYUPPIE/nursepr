defmodule NursePrepWeb.ExamLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "starting an exam creates a timed session for a subscribed user", %{conn: conn, user: user} do
    insert_question_with_options()
    subscribe!(user)

    {:ok, lv, _html} = live(conn, ~p"/exam/new")

    {:ok, _show_lv, html} =
      lv
      |> element("button", "Start exam")
      |> render_click()
      |> follow_redirect(conn)

    assert html =~ "Question 1 of"
    assert html =~ "exam-timer"
  end

  test "a free-tier user clicking start gets an upgrade prompt, not an exam", %{conn: conn} do
    insert_question_with_options()

    {:ok, lv, _html} = live(conn, ~p"/exam/new")
    html = lv |> element("button", "Start exam") |> render_click()

    assert html =~ "Premium feature"
    refute html =~ "exam-timer"
  end

  test "does not reveal correct/incorrect feedback when selecting an option", %{conn: _conn} do
    insert_question_with_options()
    user = user_fixture()

    conn = log_in_user(build_conn(), user)
    {:ok, session} = NursePrep.Quizzes.start_exam_session(user)

    {:ok, lv, _html} = live(conn, ~p"/exam/#{session.id}")
    option = hd(session.quiz_answers |> hd() |> Map.get(:question) |> Map.get(:options))

    html = lv |> element("button[phx-value-option_id='#{option.id}']") |> render_click()

    refute html =~ "Correct!"
    refute html =~ "bg-success/10"
  end

  test "submitting redirects to results and scores the exam", %{conn: _conn} do
    insert_question_with_options()
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, session} = NursePrep.Quizzes.start_exam_session(user)

    {:ok, lv, _html} = live(conn, ~p"/exam/#{session.id}")

    {:ok, _results_lv, html} =
      lv
      |> element("button", "Submit exam")
      |> render_click()
      |> follow_redirect(conn)

    assert html =~ "Results"
    assert NursePrep.Quizzes.get_session!(session.id).status == "completed"
  end

  test "an already-expired session redirects straight to results", %{conn: _conn} do
    insert_question_with_options()
    user = user_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, session} = NursePrep.Quizzes.start_exam_session(user)

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    session |> Ecto.Changeset.change(expires_at: past) |> NursePrep.Repo.update!()

    {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/exam/#{session.id}")
    assert path == ~p"/sessions/#{session.id}/results"
    assert NursePrep.Quizzes.get_session!(session.id).status == "expired"
  end
end
