defmodule NursePrepWeb.LeaderboardLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.QuizFixtures
  import NursePrep.Factory

  test "shows a message when there's no ranked activity yet", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/leaderboard")
    assert html =~ "No ranked activity yet"
  end

  test "ranks opted-in users and hides opted-out ones", %{conn: conn} do
    viewer = user_fixture()
    insert(:profile_for, user: viewer, full_name: "Viewer", leaderboard_opt_in: true)

    top_user = user_fixture()
    insert(:profile_for, user: top_user, full_name: "Top Scorer", leaderboard_opt_in: true)
    answer_n_questions(top_user, 10, correct_fraction: 1.0)

    hidden_user = user_fixture()
    insert(:profile_for, user: hidden_user, full_name: "Hidden", leaderboard_opt_in: false)
    answer_n_questions(hidden_user, 10, correct_fraction: 1.0)

    conn = log_in_user(conn, viewer)
    {:ok, _lv, html} = live(conn, ~p"/leaderboard")

    assert html =~ "Top Scorer"
    refute html =~ "Hidden"
  end

  test "switching to all-time re-queries the board", %{conn: conn} do
    viewer = user_fixture()
    old_timer = user_fixture()
    insert(:profile_for, user: old_timer, full_name: "Old Timer", leaderboard_opt_in: true)
    answer_on_date(old_timer, Date.add(Date.utc_today(), -10))

    conn = log_in_user(conn, viewer)
    {:ok, lv, html} = live(conn, ~p"/leaderboard")
    refute html =~ "Old Timer"

    html = lv |> element("button[phx-value-scope='all_time']") |> render_click()
    assert html =~ "Old Timer"
  end

  test "updates live when a session completes elsewhere", %{conn: conn} do
    viewer = user_fixture()
    conn = log_in_user(conn, viewer)
    {:ok, lv, html} = live(conn, ~p"/leaderboard")
    assert html =~ "No ranked activity yet"

    scorer = user_fixture()
    insert(:profile_for, user: scorer, full_name: "Live Scorer", leaderboard_opt_in: true)
    answer_n_questions(scorer, 5, correct_fraction: 1.0)

    assert render(lv) =~ "Live Scorer"
  end
end
