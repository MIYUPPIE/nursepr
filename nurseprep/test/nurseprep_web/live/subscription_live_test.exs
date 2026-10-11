defmodule NursePrepWeb.SubscriptionLiveTest do
  use NursePrepWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  setup do
    Application.put_env(:nurseprep, :paystack,
      secret_key: "test-secret",
      plug: {Req.Test, NursePrep.Subscriptions.PaystackClient}
    )

    :ok
  end

  test "shows the free-tier pitch and upgrade button for a user with no subscription", %{
    conn: conn
  } do
    conn = log_in_user(conn, user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/subscription")

    assert html =~ "Free tier"
    assert html =~ "Upgrade to Premium"
  end

  test "shows active status and period end for a subscribed user", %{conn: conn} do
    user = user_fixture()
    period_end = DateTime.utc_now() |> DateTime.add(15, :day) |> DateTime.truncate(:second)
    insert(:subscription, user: user, status: "active", current_period_end: period_end)

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/subscription")

    assert html =~ "You&#39;re on Premium"
    refute html =~ "Upgrade to Premium"
  end

  test "clicking upgrade redirects to the real Paystack authorization URL", %{conn: conn} do
    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{"authorization_url" => "https://paystack.test/pay/live"}
      })
    end)

    conn = log_in_user(conn, user_fixture())
    {:ok, lv, _html} = live(conn, ~p"/subscription")

    assert {:error, {:redirect, %{to: "https://paystack.test/pay/live"}}} =
             lv |> element("button", "Upgrade to Premium") |> render_click()
  end
end
