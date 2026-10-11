defmodule NursePrepWeb.PageControllerTest do
  use NursePrepWeb.ConnCase

  import NursePrep.AccountsFixtures
  import NursePrep.Factory
  import NursePrep.QuizFixtures

  test "GET / shows the marketing page to a logged-out visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "NMCN"
    assert html =~ "Log in"
    refute html =~ "Phoenix"
  end

  test "GET / has a mobile nav menu alongside the desktop one", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "hidden lg:flex"
    assert html =~ "lg:hidden"
    assert html =~ ~s(aria-label="Open menu")
  end

  test "GET / formats the premium price consistently with the rest of the app, billed quarterly",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    expected = NursePrep.Formatting.naira(NursePrep.Subscriptions.plan_amount_kobo())
    assert html =~ "₦#{expected}"
    assert html =~ "/quarter"
    refute html =~ "/month"
    refute html =~ "🔥"
  end

  test "GET / does not claim subject-based coverage-the question bank is general, not tagged",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    refute html =~ "Subjects covered"
    refute html =~ "every subject"
    assert html =~ "full question bank"
  end

  test "GET / illustrates progress against the general examination, not per-subject bars", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "General examination"
    refute html =~ "Pharmacology"
    refute html =~ "Maternal"
    refute html =~ "Psychiatric"
  end

  test "GET / shows an honest empty state when nobody has opted into the leaderboard yet",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "No ranked activity yet this week"
    refute html =~ "Student A"
    refute html =~ "Student B"
    refute html =~ "Student C"
    refute html =~ "Illustrative preview"
  end

  test "GET / shows real leaderboard entries once a student opts in and has activity",
       %{conn: conn} do
    user = user_fixture()
    insert(:profile_for, user: user, full_name: "Real Student", leaderboard_opt_in: true)
    answer_n_questions(user, 5, correct_fraction: 1.0)

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Real Student"
    assert html =~ "5 correct"
    refute html =~ "No ranked activity yet this week"
  end

  test "GET / does not show fabricated student testimonials", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    refute html =~ "Sample student"
    refute html =~ "Placeholder testimonial"
    refute html =~ "What students are saying"
  end

  test "GET / redirects a logged-in user straight to their dashboard", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/dashboard"
  end
end
