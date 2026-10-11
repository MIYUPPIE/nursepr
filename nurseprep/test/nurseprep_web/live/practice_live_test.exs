defmodule NursePrepWeb.PracticeLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  test "starting practice navigates into a session", %{conn: conn} do
    insert_question_with_options()
    {:ok, lv, _html} = live(conn, ~p"/practice")

    {:ok, _show_lv, html} =
      lv
      |> element("button", "Start practice")
      |> render_click()
      |> follow_redirect(conn)

    assert html =~ "Question 1 of"
  end

  test "the start page has no subject selector-questions are general, not subject-filtered",
       %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/practice")

    refute html =~ "Subject"
    refute html =~ "select"
    assert html =~ "full question bank"
  end

  test "answering shows instant feedback and the explanation", %{conn: conn} do
    question = insert_question_with_options()

    {:ok, _} =
      NursePrep.Questions.upsert_explanation(question.id, %{
        "body" => "Because B is right.",
        "generated_by" => "human"
      })

    {:ok, lv, _html} =
      live(conn, ~p"/practice")

    {:ok, show_lv, _html} =
      lv
      |> element("button", "Start practice")
      |> render_click()
      |> follow_redirect(conn)

    correct_option = Enum.find(question.options, & &1.is_correct)

    html =
      show_lv |> element("button[phx-value-option_id='#{correct_option.id}']") |> render_click()

    assert html =~ "Correct!"
    assert html =~ "Because B is right."
  end

  test "answering incorrectly shows \"Incorrect\" feedback", %{conn: conn} do
    question = insert_question_with_options()

    {:ok, lv, _html} = live(conn, ~p"/practice")

    {:ok, show_lv, _html} =
      lv
      |> element("button", "Start practice")
      |> render_click()
      |> follow_redirect(conn)

    wrong_option = Enum.find(question.options, &(!&1.is_correct))

    html =
      show_lv |> element("button[phx-value-option_id='#{wrong_option.id}']") |> render_click()

    assert html =~ "Incorrect"
    refute html =~ "Not quite"
  end

  test "a topic_id query param auto-starts a session filtered to that topic", %{conn: conn} do
    topic = insert(:topic)
    insert_question_with_options(topic: topic, subject: topic.subject)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/practice?topic_id=#{topic.id}")

    {:ok, _show_lv, html} = live(conn, to)
    assert html =~ "Question 1 of"
  end

  test "a subject_id query param auto-starts a session filtered to that subject", %{conn: conn} do
    subject = insert(:subject)
    insert_question_with_options(subject: subject)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/practice?subject_id=#{subject.id}")

    {:ok, _show_lv, html} = live(conn, to)
    assert html =~ "Question 1 of"
  end

  test "starting practice with no published questions flashes instead of crashing", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/practice")

    html =
      lv
      |> element("button", "Start practice")
      |> render_click()

    assert html =~ "No published questions available"
  end

  test "cannot view another user's session", %{conn: conn} do
    other_user = user_fixture()
    insert_question_with_options()
    {:ok, session} = NursePrep.Quizzes.start_practice_session(other_user, %{})

    {:error, {:live_redirect, %{to: path, flash: flash}}} =
      live(conn, ~p"/practice/#{session.id}")

    assert path == ~p"/practice"
    assert flash["error"] =~ "isn't yours"
  end
end
