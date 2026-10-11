defmodule NursePrepWeb.SubscriptionCallbackControllerTest do
  use NursePrepWeb.ConnCase, async: false

  import NursePrep.AccountsFixtures

  alias NursePrep.Subscriptions
  alias NursePrep.Subscriptions.Payment

  setup do
    Application.put_env(:nurseprep, :paystack,
      secret_key: "test-secret",
      plug: {Req.Test, NursePrep.Subscriptions.PaystackClient}
    )

    :ok
  end

  test "a successful payment redirects to /subscription, confirms it, and activates premium", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, payment} = insert_pending_payment(user)

    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{
          "reference" => payment.paystack_reference,
          "status" => "success",
          "customer" => %{"customer_code" => "CUS_123"}
        }
      })
    end)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/subscription/callback?reference=#{payment.paystack_reference}")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Payment confirmed"
    assert Subscriptions.active?(user)
  end

  test "a still-processing transaction redirects with an informational flash and grants nothing",
       %{
         conn: conn
       } do
    user = user_fixture()
    {:ok, payment} = insert_pending_payment(user)

    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{"reference" => payment.paystack_reference, "status" => "processing"}
      })
    end)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/subscription/callback?reference=#{payment.paystack_reference}")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "still confirming"
    refute Subscriptions.active?(user)
  end

  test "an abandoned checkout redirects with an error flash telling the user to try again", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, payment} = insert_pending_payment(user)

    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{"reference" => payment.paystack_reference, "status" => "abandoned"}
      })
    end)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/subscription/callback?reference=#{payment.paystack_reference}")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't go through"
    refute Subscriptions.active?(user)
  end

  test "a reference with no matching payment redirects with a not-found error flash", %{
    conn: conn
  } do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/subscription/callback?reference=does-not-exist")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "couldn't find that payment"
  end

  test "a missing reference param redirects with an error flash instead of crashing", %{
    conn: conn
  } do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/subscription/callback")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing payment reference"
  end

  test "a reference belonging to someone else confirms nothing for either user", %{conn: conn} do
    owner = user_fixture()
    intruder = user_fixture()
    {:ok, payment} = insert_pending_payment(owner)

    conn =
      conn
      |> log_in_user(intruder)
      |> get(~p"/subscription/callback?reference=#{payment.paystack_reference}")

    assert redirected_to(conn) == ~p"/subscription"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "couldn't find that payment"
    refute Subscriptions.active?(owner)
    refute Subscriptions.active?(intruder)
  end

  test "redirects to the login page when nobody is signed in", %{conn: conn} do
    conn = get(conn, ~p"/subscription/callback?reference=whatever")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  defp insert_pending_payment(user) do
    %Payment{}
    |> Payment.changeset(%{
      "user_id" => user.id,
      "paystack_reference" => "ref-#{System.unique_integer([:positive])}",
      "amount_kobo" => Subscriptions.plan_amount_kobo(),
      "status" => "pending"
    })
    |> NursePrep.Repo.insert()
  end
end
