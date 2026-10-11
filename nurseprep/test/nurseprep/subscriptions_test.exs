defmodule NursePrep.SubscriptionsTest do
  use NursePrep.DataCase, async: false

  import NursePrep.Factory
  import NursePrep.AccountsFixtures

  alias NursePrep.Subscriptions
  alias NursePrep.Subscriptions.Payment

  setup do
    Application.put_env(:nurseprep, :paystack,
      secret_key: "test-secret",
      public_key: "test-public",
      plug: {Req.Test, NursePrep.Subscriptions.PaystackClient}
    )

    :ok
  end

  describe "active?/1 and can_start_exam?/1" do
    test "a user with no subscription is not active and can't sit an exam" do
      user = user_fixture()
      refute Subscriptions.active?(user)
      assert Subscriptions.can_start_exam?(user) == {:error, :subscription_required}
    end

    test "an active, unexpired subscription grants access" do
      user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "active", current_period_end: period_end)

      assert Subscriptions.active?(user)
      assert Subscriptions.can_start_exam?(user) == :ok
    end

    test "an expired-by-date subscription does not grant access even if status still says active" do
      user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "active", current_period_end: period_end)

      refute Subscriptions.active?(user)
    end
  end

  describe "can_start_practice?/1" do
    test "allows practice under the free daily limit" do
      user = user_fixture()
      assert Subscriptions.can_start_practice?(user) == :ok
    end

    test "blocks practice once the free daily limit is reached" do
      user = user_fixture()
      limit = Subscriptions.free_daily_practice_limit()
      for _ <- 1..limit, do: insert_question_with_options()

      {:ok, session} = NursePrep.Quizzes.start_practice_session(user, %{}, question_count: limit)

      Enum.each(session.quiz_answers, fn answer ->
        option = hd(answer.question.options)
        NursePrep.Quizzes.answer_question(session, answer.question_id, option.id)
      end)

      assert Subscriptions.can_start_practice?(user) == {:error, :daily_limit_reached}
    end

    test "an active subscriber is never limited" do
      user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "active", current_period_end: period_end)

      assert Subscriptions.can_start_practice?(user) == :ok
    end
  end

  describe "checkout_url/1" do
    test "creates a pending payment and returns the Paystack authorization URL" do
      user = user_fixture()

      Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["amount"] == Subscriptions.plan_amount_kobo()
        assert decoded["email"] =~ "@users.nurseprep.ng"

        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{
            "authorization_url" => "https://paystack.test/pay/abc",
            "reference" => decoded["reference"]
          }
        })
      end)

      assert {:ok, "https://paystack.test/pay/abc"} = Subscriptions.checkout_url(user)
      assert [%Payment{status: "pending"}] = Repo.all(Payment)
    end
  end

  describe "handle_paystack_event/2" do
    test "charge.success activates a subscription and marks the payment successful" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      assert {:ok, subscription} =
               Subscriptions.handle_paystack_event("charge.success", %{
                 "reference" => payment.paystack_reference,
                 "customer" => %{"customer_code" => "CUS_123"}
               })

      assert subscription.status == "active"
      assert subscription.paystack_customer_code == "CUS_123"
      assert Subscriptions.active?(user)
      assert Repo.get!(Payment, payment.id).status == "success"
    end

    test "is idempotent-processing the same event twice doesn't double-extend" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)
      event_data = %{"reference" => payment.paystack_reference, "customer" => %{}}

      {:ok, sub1} = Subscriptions.handle_paystack_event("charge.success", event_data)
      result2 = Subscriptions.handle_paystack_event("charge.success", event_data)

      assert result2 == :already_processed

      assert Repo.get!(NursePrep.Subscriptions.Subscription, sub1.id).current_period_end ==
               sub1.current_period_end
    end

    test "subscription.disable expires the user's subscription" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      {:ok, _} =
        Subscriptions.handle_paystack_event("charge.success", %{
          "reference" => payment.paystack_reference,
          "customer" => %{}
        })

      assert {:ok, subscription} =
               Subscriptions.handle_paystack_event("subscription.disable", %{
                 "reference" => payment.paystack_reference
               })

      assert subscription.status == "expired"
      refute Subscriptions.active?(user)
    end

    test "an event for an unknown reference returns an error tuple, not a crash" do
      assert Subscriptions.handle_paystack_event("charge.success", %{
               "reference" => "does-not-exist"
             }) ==
               {:error, :payment_not_found}
    end

    test "a renewal payment while still active stacks the new period on top of the remaining time, instead of discarding it" do
      user = user_fixture()
      period_start = DateTime.utc_now() |> DateTime.add(-20, :day) |> DateTime.truncate(:second)
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

      insert(:subscription,
        user: user,
        status: "active",
        current_period_start: period_start,
        current_period_end: period_end
      )

      {:ok, payment} = insert_pending_payment(user)

      assert {:ok, subscription} =
               Subscriptions.handle_paystack_event("charge.success", %{
                 "reference" => payment.paystack_reference,
                 "customer" => %{}
               })

      # 10 days left + a fresh 90-day (3-month) period = 100 days out, not
      # 90-the days the user already paid for aren't thrown away by an
      # early renewal.
      assert DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day) in 99..100
      assert subscription.current_period_start == period_start
    end

    test "a renewal payment after expiry starts a fresh 3-month window from now, not from the old expiry" do
      user = user_fixture()
      old_period_end = DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "expired", current_period_end: old_period_end)

      {:ok, payment} = insert_pending_payment(user)

      assert {:ok, subscription} =
               Subscriptions.handle_paystack_event("charge.success", %{
                 "reference" => payment.paystack_reference,
                 "customer" => %{}
               })

      assert DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day) in 89..90
    end
  end

  describe "grant_manual_subscription/2" do
    test "stacks onto remaining time for a user who's still active" do
      user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "active", current_period_end: period_end)

      {:ok, subscription} = Subscriptions.grant_manual_subscription(user, 30)

      assert DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day) in 39..40
    end

    test "starts fresh for a user with no existing subscription" do
      user = user_fixture()
      {:ok, subscription} = Subscriptions.grant_manual_subscription(user, 30)

      assert DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day) in 29..30
    end

    test "defaults to 90 days (3 months) when no explicit day count is given" do
      user = user_fixture()
      {:ok, subscription} = Subscriptions.grant_manual_subscription(user)

      assert DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day) in 89..90
    end
  end

  describe "confirm_payment/2" do
    test "a successful verify activates the subscription, same as the webhook would" do
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

      assert {:ok, subscription} = Subscriptions.confirm_payment(user, payment.paystack_reference)
      assert subscription.status == "active"
      assert Subscriptions.active?(user)
    end

    test "is a no-op if the webhook already processed the same reference" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      {:ok, _} =
        Subscriptions.handle_paystack_event("charge.success", %{
          "reference" => payment.paystack_reference,
          "customer" => %{}
        })

      Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{"reference" => payment.paystack_reference, "status" => "success"}
        })
      end)

      assert Subscriptions.confirm_payment(user, payment.paystack_reference) == :already_processed
    end

    test "a still-processing transaction returns {:error, :pending} and leaves the payment row untouched" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{"reference" => payment.paystack_reference, "status" => "processing"}
        })
      end)

      assert Subscriptions.confirm_payment(user, payment.paystack_reference) == {:error, :pending}
      refute Subscriptions.active?(user)
      assert Repo.get!(Payment, payment.id).status == "pending"
    end

    test "a failed transaction returns {:error, :failed} and marks the payment row failed" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{"reference" => payment.paystack_reference, "status" => "failed"}
        })
      end)

      assert Subscriptions.confirm_payment(user, payment.paystack_reference) == {:error, :failed}
      assert Repo.get!(Payment, payment.id).status == "failed"
    end

    test "an abandoned checkout returns {:error, :failed} and marks the payment row abandoned" do
      user = user_fixture()
      {:ok, payment} = insert_pending_payment(user)

      Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{"reference" => payment.paystack_reference, "status" => "abandoned"}
        })
      end)

      assert Subscriptions.confirm_payment(user, payment.paystack_reference) == {:error, :failed}
      assert Repo.get!(Payment, payment.id).status == "abandoned"
      refute Subscriptions.active?(user)
    end

    test "a reference that doesn't belong to the caller returns {:error, :not_found}, and grants nothing" do
      owner = user_fixture()
      intruder = user_fixture()
      {:ok, payment} = insert_pending_payment(owner)

      assert Subscriptions.confirm_payment(intruder, payment.paystack_reference) ==
               {:error, :not_found}

      refute Subscriptions.active?(owner)
      refute Subscriptions.active?(intruder)
    end

    test "an unknown reference returns {:error, :not_found}" do
      user = user_fixture()
      assert Subscriptions.confirm_payment(user, "does-not-exist") == {:error, :not_found}
    end
  end

  describe "count_active/0" do
    test "counts only active, unexpired subscriptions" do
      active_user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: active_user, status: "active", current_period_end: period_end)

      expired_user = user_fixture()
      expired_end = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      insert(:subscription,
        user: expired_user,
        status: "active",
        current_period_end: expired_end
      )

      pending_user = user_fixture()
      insert(:subscription, user: pending_user, status: "pending")

      assert Subscriptions.count_active() == 1
    end
  end

  describe "list_recent_successful_payments/1" do
    test "returns only successful payments, newest-paid first" do
      user = user_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      older_success =
        insert(:payment,
          user: user,
          status: "success",
          paid_at: DateTime.add(now, -3600, :second)
        )

      newer_success = insert(:payment, user: user, status: "success", paid_at: now)
      insert(:payment, user: user, status: "pending")
      insert(:payment, user: user, status: "failed")

      results = Subscriptions.list_recent_successful_payments()

      assert Enum.map(results, & &1.id) == [newer_success.id, older_success.id]
      assert Enum.all?(results, &(&1.status == "success"))
    end

    test "respects the limit" do
      user = user_fixture()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..3 do
        insert(:payment, user: user, status: "success", paid_at: now)
      end

      assert length(Subscriptions.list_recent_successful_payments(2)) == 2
    end
  end

  defp insert_pending_payment(user) do
    %Payment{}
    |> Payment.changeset(%{
      "user_id" => user.id,
      "paystack_reference" => "ref-#{System.unique_integer([:positive])}",
      "amount_kobo" => Subscriptions.plan_amount_kobo(),
      "status" => "pending"
    })
    |> Repo.insert()
  end
end
