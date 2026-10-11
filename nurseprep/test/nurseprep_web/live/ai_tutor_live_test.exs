defmodule NursePrepWeb.AiTutorLiveTest do
  use NursePrepWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.AiTutorFixtures
  import NursePrep.Factory
  import NursePrep.QuizFixtures

  setup %{conn: conn} do
    stub_xai!()
    user = user_fixture() |> tap(&subscribe!/1)
    %{conn: log_in_user(conn, user), user: user}
  end

  test "asking a question shows the reply once it comes back", %{conn: conn} do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "PHC stands for Primary Health Care."
            }
          }
        ],
        "usage" => %{}
      })
    end)

    {:ok, lv, _html} = live(conn, ~p"/tutor")

    lv |> form("form", chat: %{question: "What is PHC?"}) |> render_submit()

    assert render(lv) =~ "What is PHC?"

    # Async reply lands via handle_async-wait for it to show up.
    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Primary Health Care",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
    assert html =~ "Primary Health Care."
  end

  test "renders the tutor's markdown formatting instead of literal asterisks", %{conn: conn} do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" =>
                "**PHC** stands for *Primary Health Care* and covers:\n- Prevention\n- Promotion"
            }
          }
        ],
        "usage" => %{}
      })
    end)

    {:ok, lv, _html} = live(conn, ~p"/tutor")

    lv |> form("form", chat: %{question: "What is PHC?"}) |> render_submit()

    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Primary Health Care",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
    assert html =~ "<strong>PHC</strong>"
    assert html =~ "<em>Primary Health Care</em>"
    assert html =~ "<li>Prevention</li>"
    refute html =~ "**PHC**"
    refute html =~ "*Primary Health Care*"
  end

  test "asking a question replaces the suggested-questions empty state", %{conn: conn} do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Primary Health Care."}}
        ],
        "usage" => %{}
      })
    end)

    {:ok, lv, html} = live(conn, ~p"/tutor")
    assert html =~ "Ask your AI tutor anything"

    lv
    |> element("button[phx-click=ask_suggested]", "Walk me through the stages of labour.")
    |> render_click()

    html = render(lv)
    assert html =~ "Walk me through the stages of labour."
    refute html =~ "Ask your AI tutor anything"

    # Wait for the async reply so the test doesn't tear down mid-flight.
    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Primary Health Care.",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
  end

  test "shows a friendly error when the tutor call fails", %{conn: conn} do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Plug.Conn.put_status(conn, 500) |> Req.Test.json(%{})
    end)

    {:ok, lv, _html} = live(conn, ~p"/tutor")
    lv |> form("form", chat: %{question: "hi"}) |> render_submit()

    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "unavailable",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
  end

  test "the explain-my-weak-areas button surfaces the AI's grounded reply", %{
    conn: conn,
    user: user
  } do
    topic = insert(:topic, name: "Pharmacology")
    answer_topic_questions(user, topic, 10, correct_fraction: 0.2)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Focus on dosage math."}}
        ],
        "usage" => %{}
      })
    end)

    {:ok, lv, _html} = live(conn, ~p"/tutor")
    lv |> element("button", "Explain my weak areas") |> render_click()

    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Focus on dosage math.",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
    assert html =~ "Pharmacology"
  end

  test "landing on /tutor?explain=weak_areas auto-triggers the explanation", %{
    conn: conn,
    user: user
  } do
    topic = insert(:topic, name: "Community Health")
    answer_topic_questions(user, topic, 10, correct_fraction: 0.2)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Review outreach programs."}}
        ],
        "usage" => %{}
      })
    end)

    {:ok, lv, _html} = live(conn, ~p"/tutor?explain=weak_areas")

    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Review outreach programs.",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
  end

  test "a free-tier user gets an upgrade prompt instead of a reply", %{conn: _conn} do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn _conn ->
      flunk("Grok should never be called for a free-tier user")
    end)

    free_user = user_fixture()
    conn = log_in_user(build_conn(), free_user)

    {:ok, lv, _html} = live(conn, ~p"/tutor")
    lv |> form("form", chat: %{question: "What is PHC?"}) |> render_submit()

    html =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        html = render(lv)

        if html =~ "Premium feature",
          do: {:halt, html},
          else:
            (
              Process.sleep(10)
              {:cont, nil}
            )
      end)

    assert html
    assert html =~ "Premium feature"
  end
end
