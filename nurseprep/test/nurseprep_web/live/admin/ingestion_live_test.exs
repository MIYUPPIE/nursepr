defmodule NursePrepWeb.Admin.IngestionLiveTest do
  # async: false because ingestion runs in a separately-supervised Task; the
  # SQL Sandbox only auto-shares the DB connection with the test process
  # itself under async mode, and this Task needs to reach the database too.
  use NursePrepWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_fixture())}
  end

  test "renders the configured (fixture, in test) source path", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/admin/ingestion")
    assert html =~ "test/fixtures/sample_questions.docx"
  end

  test "running ingestion against the fixture creates draft questions and shows a summary", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/admin/ingestion")

    lv |> element("button", "Run ingestion") |> render_click()

    # The conversion + parse + insert run in a separate supervised task and
    # report back via handle_info, so poll briefly rather than assuming
    # it's synchronous.
    assert wait_until(fn -> render(lv) =~ "Run complete" end)

    html = render(lv)
    assert html =~ "Created: 2"
    assert length(NursePrep.Questions.list_questions(%{})) == 2
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
