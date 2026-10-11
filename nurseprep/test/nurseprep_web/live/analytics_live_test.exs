defmodule NursePrepWeb.AnalyticsLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.QuizFixtures
  import NursePrep.Factory

  test "shows a placeholder when nothing's been answered yet", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/analytics")
    assert html =~ "show up here"
  end

  test "renders a per-topic accuracy bar and a weak-area CTA", %{conn: conn} do
    user = user_fixture()
    weak_topic = insert(:topic, name: "Pharmacology Weak")
    answer_topic_questions(user, weak_topic, 10, correct_fraction: 0.2)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/analytics")

    assert html =~ "Pharmacology Weak"
    assert html =~ "Drill it now"
    assert html =~ ~p"/practice?topic_id=#{weak_topic.id}"
    assert html =~ "Ask AI to explain"
    assert html =~ ~p"/tutor?explain=weak_areas"
  end
end
