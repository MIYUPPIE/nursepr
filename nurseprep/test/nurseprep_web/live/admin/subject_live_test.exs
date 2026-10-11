defmodule NursePrepWeb.Admin.SubjectLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_fixture())}
  end

  test "creates a new subject", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/subjects")

    lv |> element("button", "New subject") |> render_click()

    html =
      lv
      |> form("form",
        subject: %{name: "Pharmacology", slug: "pharmacology", description: "Drugs"}
      )
      |> render_submit()

    assert html =~ "Subject saved."
    assert html =~ "Pharmacology"
  end

  test "edits an existing subject", %{conn: conn} do
    _subject = insert(:subject, name: "Old Name", slug: "old-slug")

    {:ok, lv, _html} = live(conn, ~p"/admin/subjects")
    lv |> element("a", "Edit") |> render_click()

    html =
      lv
      |> form("form", subject: %{name: "New Name"})
      |> render_submit()

    assert html =~ "New Name"
    refute html =~ "Old Name"
  end
end
