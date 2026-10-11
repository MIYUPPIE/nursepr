defmodule NursePrepWeb.Admin.UserLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  alias NursePrep.Accounts

  test "a reviewer is denied-this page is admin-only", %{conn: conn} do
    reviewer = user_fixture()
    {:ok, reviewer} = Accounts.promote_to_role(reviewer, "reviewer")
    conn = log_in_user(conn, reviewer)

    assert {:error, {:redirect, %{to: "/admin", flash: flash}}} =
             live(conn, ~p"/admin/users")

    assert flash["error"] =~ "Only admins"
  end

  test "a non-admin student is redirected away entirely", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/users")
  end

  test "lists users with their profile, role, and subscription status", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    insert(:profile_for, user: student, full_name: "Ada Nurse")
    insert(:subscription, user: student, status: "active", current_period_end: future())

    conn = log_in_user(conn, admin)
    {:ok, _lv, html} = live(conn, ~p"/admin/users")

    assert html =~ student.phone
    assert html =~ "Ada Nurse"
    assert html =~ "Active"
  end

  test "search filters by phone", %{conn: conn} do
    admin = admin_fixture()
    match = user_fixture(phone: "+2348011112222")
    other = user_fixture()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html = lv |> form("form[phx-change='search']") |> render_change(%{"search" => "1111"})

    assert html =~ match.phone
    refute html =~ other.phone
  end

  test "changing a user's role takes effect immediately", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> element("#role-form-#{student.id}")
    |> render_change(%{"role" => "reviewer"})

    assert Accounts.get_user!(student.id).role == "reviewer"
  end

  test "changing a user's phone takes effect immediately", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    new_phone = unique_user_phone()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html =
      lv
      |> element("#phone-form-#{student.id}")
      |> render_change(%{"phone" => new_phone})

    assert html =~ "Phone updated."
    assert Accounts.get_user!(student.id).phone == new_phone
  end

  test "rejects a phone already belonging to another user, with a clear error", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    other = user_fixture()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html =
      lv
      |> element("#phone-form-#{student.id}")
      |> render_change(%{"phone" => other.phone})

    assert html =~ "already been taken"
    assert Accounts.get_user!(student.id).phone == student.phone
  end

  test "changing a user's email takes effect immediately", %{conn: conn} do
    admin = admin_fixture()
    student = email_user_fixture()
    new_email = unique_user_email()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html =
      lv
      |> element("#email-form-#{student.id}")
      |> render_change(%{"email" => new_email})

    assert html =~ "Email updated."
    assert Accounts.get_user!(student.id).email == new_email
  end

  test "deleting a user removes them from the list", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()

    conn = log_in_user(conn, admin)
    {:ok, lv, html} = live(conn, ~p"/admin/users")
    assert html =~ student.phone

    html =
      lv
      |> element("button[phx-click='delete_user'][phx-value-user_id='#{student.id}']")
      |> render_click()

    assert html =~ "deleted."
    refute html =~ "phone-form-#{student.id}"
    refute Accounts.get_user_by_phone(student.phone)
  end

  test "an admin cannot delete their own account from this page", %{conn: conn} do
    admin = admin_fixture()

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    refute has_element?(lv, "button[phx-click='delete_user'][phx-value-user_id='#{admin.id}']")
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
end
