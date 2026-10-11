defmodule NursePrepWeb.Admin.QuestionLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  setup %{conn: conn} do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  describe "Index" do
    test "lists questions and filters by status", %{conn: conn} do
      insert(:question, status: "published", stem: "Published one")
      insert(:question, status: "draft", stem: "Draft one")

      {:ok, lv, html} = live(conn, ~p"/admin/questions")
      assert html =~ "Published one"
      assert html =~ "Draft one"

      html = lv |> element("form") |> render_change(%{"status" => "published"})
      assert html =~ "Published one"
      refute html =~ "Draft one"
    end

    test "bulk publish moves selected drafts to published", %{conn: conn} do
      q1 = insert(:question, status: "draft")
      q2 = insert(:question, status: "draft")

      {:ok, lv, _html} = live(conn, ~p"/admin/questions")

      lv |> element("input[phx-value-id='#{q1.id}']") |> render_click()
      lv |> element("input[phx-value-id='#{q2.id}']") |> render_click()
      html = lv |> element("button", "Publish") |> render_click()

      assert html =~ "Published 2"
      assert NursePrep.Questions.get_question!(q1.id).status == "published"
      assert NursePrep.Questions.get_question!(q2.id).status == "published"
    end
  end

  describe "Index new question button" do
    test "links to the new question page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/questions")

      {:ok, _new_lv, html} =
        lv
        |> element("a", "New question")
        |> render_click()
        |> follow_redirect(conn, ~p"/admin/questions/new")

      assert html =~ "New question"
    end
  end

  describe "New" do
    test "renders the form with four default option rows", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/questions/new")

      assert html =~ "New question"
      assert html =~ ~s(name="options[0][body]")
      assert html =~ ~s(name="options[3][body]")
      refute html =~ ~s(name="options[4][body]")
    end

    test "adding and removing option rows adjusts the form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/new")

      html = lv |> element("button", "Add option") |> render_click()
      assert html =~ ~s(name="options[4][body]")

      html =
        lv
        |> element("button[phx-value-index='4']")
        |> render_click()

      refute html =~ ~s(name="options[4][body]")
    end

    test "creates a question with options and redirects to the show page", %{conn: conn} do
      subject = insert(:subject)

      {:ok, lv, _html} = live(conn, ~p"/admin/questions/new")

      {:ok, _show_lv, html} =
        lv
        |> form("#question-form",
          question: %{
            "stem" => "What is the hallmark of PHC?",
            "question_type" => "mcq",
            "status" => "draft",
            "subject_id" => subject.id
          },
          options: %{
            "0" => %{"body" => "Community participation"},
            "1" => %{"body" => "Hospital-centred care"},
            "2" => %{"body" => "Curative focus"},
            "3" => %{"body" => "Specialist referral"}
          },
          correct_option: "0"
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Question created."
      assert html =~ "What is the hallmark of PHC?"

      question =
        NursePrep.Questions.list_questions()
        |> Enum.find(&(&1.stem == "What is the hallmark of PHC?"))

      assert question.subject_id == subject.id
      assert length(question.options) == 4
      assert Enum.find(question.options, & &1.is_correct).body == "Community participation"
    end

    test "rejects submission with fewer than two options filled in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/new")

      html =
        lv
        |> form("#question-form",
          question: %{
            "stem" => "Incomplete question",
            "question_type" => "mcq",
            "status" => "draft"
          },
          options: %{"0" => %{"body" => "Only one option"}},
          correct_option: "0"
        )
        |> render_submit()

      assert html =~ "Add at least 2 options"

      refute NursePrep.Questions.list_questions()
             |> Enum.any?(&(&1.stem == "Incomplete question"))
    end

    test "rejects submission with no option marked correct", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/new")

      html =
        lv
        |> form("#question-form",
          question: %{
            "stem" => "No correct answer question",
            "question_type" => "mcq",
            "status" => "draft"
          },
          options: %{
            "0" => %{"body" => "Option one"},
            "1" => %{"body" => "Option two"}
          }
        )
        |> render_submit()

      assert html =~ "Mark one option as correct."

      refute NursePrep.Questions.list_questions()
             |> Enum.any?(&(&1.stem == "No correct answer question"))
    end

    test "shows validation errors when the stem is blank", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/new")

      html =
        lv
        |> form("#question-form",
          question: %{
            "stem" => "",
            "question_type" => "mcq"
          },
          options: %{
            "0" => %{"body" => "Option one"},
            "1" => %{"body" => "Option two"}
          },
          correct_option: "0"
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "Show" do
    test "renders the diff between raw_stem and stem", %{conn: conn} do
      question =
        insert(:question,
          raw_stem: "The hallmark of Primry Health Care",
          stem: "The hallmark of Primary Health Care"
        )

      {:ok, _lv, html} = live(conn, ~p"/admin/questions/#{question.id}")
      assert html =~ "Diff vs. original"
    end

    test "publish button publishes the question", %{conn: conn} do
      question = insert(:question, status: "draft")
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/#{question.id}")

      lv |> element("button", "Publish") |> render_click()

      assert NursePrep.Questions.get_question!(question.id).status == "published"
    end

    test "saving an explanation persists it", %{conn: conn} do
      question = insert(:question)
      {:ok, lv, _html} = live(conn, ~p"/admin/questions/#{question.id}")

      html =
        lv
        |> form("form",
          explanation: %{body: "Because option B directly reflects the PHC principle."}
        )
        |> render_submit()

      assert html =~ "Explanation saved."
    end
  end
end
