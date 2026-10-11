defmodule NursePrepWeb.Admin.SubscriptionLiveTest do
  use NursePrepWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  alias NursePrep.{Accounts, Subscriptions}

  test "a reviewer is denied-this page is admin-only", %{conn: conn} do
    reviewer = user_fixture()
    {:ok, reviewer} = Accounts.promote_to_role(reviewer, "reviewer")
    conn = log_in_user(conn, reviewer)

    assert {:error, {:redirect, %{to: "/admin", flash: flash}}} =
             live(conn, ~p"/admin/subscriptions")

    assert flash["error"] =~ "Only admins"
  end

  test "lists subscriptions and recent payments", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    insert(:profile_for, user: student, full_name: "Ada Nurse")

    subscription =
      insert(:subscription, user: student, status: "active", current_period_end: future())

    insert(:payment,
      user: student,
      subscription: subscription,
      paystack_reference: "ref-abc",
      amount_kobo: 500_000,
      status: "success",
      paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )

    conn = log_in_user(conn, admin)
    {:ok, _lv, html} = live(conn, ~p"/admin/subscriptions")

    assert html =~ student.phone
    assert html =~ "Ada Nurse"
    assert html =~ "active"
    assert html =~ "ref-abc"
  end

  test "filtering by status only shows matching subscriptions", %{conn: conn} do
    admin = admin_fixture()
    active_user = user_fixture()
    expired_user = user_fixture()

    insert(:subscription, user: active_user, status: "active", current_period_end: future())
    insert(:subscription, user: expired_user, status: "expired", current_period_end: past())

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/subscriptions")

    html = lv |> element("button", "Active") |> render_click()
    assert html =~ active_user.phone
    refute html =~ expired_user.phone
  end

  test "manually granting access to a phone number activates their subscription", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    refute Subscriptions.active?(student)

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/subscriptions")

    html =
      lv
      |> form("#manual-grant-form", %{"identifier" => student.phone, "days" => "30"})
      |> render_submit()

    assert html =~ "Granted 30 days"
    assert Subscriptions.active?(student)
  end

  test "manually granting access by email activates a phone-less user's subscription", %{
    conn: conn
  } do
    admin = admin_fixture()
    student = email_user_fixture()
    refute Subscriptions.active?(student)

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/subscriptions")

    html =
      lv
      |> form("#manual-grant-form", %{"identifier" => student.email, "days" => "30"})
      |> render_submit()

    assert html =~ "Granted 30 days"
    assert Subscriptions.active?(student)
  end

  test "granting to an unknown phone number shows an error, not a crash", %{conn: conn} do
    admin = admin_fixture()
    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/subscriptions")

    html =
      lv
      |> form("#manual-grant-form", %{"identifier" => "+2340000000000", "days" => "30"})
      |> render_submit()

    assert html =~ "No user found"
  end

  test "revoking an active subscription expires it immediately", %{conn: conn} do
    admin = admin_fixture()
    student = user_fixture()
    insert(:subscription, user: student, status: "active", current_period_end: future())

    conn = log_in_user(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/subscriptions")

    lv |> element("a", "Revoke") |> render_click()

    refute Subscriptions.active?(student)
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
  defp past, do: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
end
