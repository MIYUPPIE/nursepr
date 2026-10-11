defmodule NursePrep.Subscriptions do
  @moduledoc """
  Single-plan subscription entitlement, backed by one-off Paystack charges
  rather than Paystack's recurring subscription/plan API-simpler to
  reason about and to test, at the cost of the user re-paying manually
  every billing period rather than being auto-charged. A successful charge
  extends (or creates) a 3-month (90-day) access window; nothing here assumes a
  Paystack "subscription" object exists, though `handle_paystack_event/2`
  still reacts sanely to `subscription.disable` if one's ever configured
  from the Paystack dashboard directly.
  """

  import Ecto.Query, warn: false

  alias NursePrep.Repo
  alias NursePrep.Subscriptions.{Subscription, Payment, PaystackEvent, PaystackClient}

  @plan_amount_kobo Application.compile_env(:nurseprep, :subscription_amount_kobo, 500_000)
  # 3 months, expressed in days like the rest of this module's period math —
  # no calendar-month arithmetic, same approximation @period_days already
  # made at 30 for "1 month".
  @period_days 90

  def plan_amount_kobo, do: @plan_amount_kobo

  @doc "Whether `user` currently has paid access (active subscription, not yet expired)."
  def active?(user) do
    now = DateTime.utc_now()

    Repo.exists?(
      from s in Subscription,
        where: s.user_id == ^user.id and s.status == "active" and s.current_period_end > ^now
    )
  end

  @doc """
  Practice paywall: free tier gets a limited number of practice questions
  per day (across every channel); an active subscription lifts the limit
  entirely.
  """
  def can_start_practice?(user) do
    if active?(user) or
         NursePrep.Quizzes.practice_questions_answered_today(user) < free_daily_practice_limit() do
      :ok
    else
      {:error, :daily_limit_reached}
    end
  end

  @doc "Mock exams are a paid-tier feature-free accounts practice, but don't sit the timed exam."
  def can_start_exam?(user) do
    if active?(user), do: :ok, else: {:error, :subscription_required}
  end

  def free_daily_practice_limit,
    do: Application.get_env(:nurseprep, :free_daily_practice_limit, 10)

  def list_payments(user) do
    Repo.all(from p in Payment, where: p.user_id == ^user.id, order_by: [desc: p.inserted_at])
  end

  def get_active_subscription(user) do
    now = DateTime.utc_now()

    Repo.one(
      from s in Subscription,
        where: s.user_id == ^user.id and s.status == "active" and s.current_period_end > ^now
    )
  end

  @doc "Initializes a Paystack checkout and returns the authorization URL to redirect the user to."
  def checkout_url(user) do
    reference = generate_reference(user)

    with {:ok, _payment} <- create_pending_payment(user, reference),
         {:ok, %{"authorization_url" => url}} <-
           PaystackClient.initialize_transaction(user, @plan_amount_kobo, reference) do
      {:ok, url}
    end
  end

  @doc """
  Synchronous fallback for the browser's redirect back from Paystack
  checkout (`/subscription/callback`). Verifies the transaction directly
  against Paystack's API and reconciles it through the same idempotent
  `handle_paystack_event/2` path the webhook itself uses, so whichever of
  the two-this callback or the webhook-arrives first does the real
  work and the other is a no-op. This exists because webhook delivery,
  while normally near-instant, is never guaranteed to beat the user's own
  redirect back to the app.

  Scoped to `user`: only resolves a reference that belongs to `user`'s own
  payment history, so a guessed or shared reference can't be used to probe
  or force-confirm someone else's payment.

  A definitive non-success verdict from Paystack ("failed", "abandoned",
  etc.) is persisted onto the `Payment` row so the admin payments view
  reflects reality instead of showing it stuck on "pending" forever.
  """
  def confirm_payment(user, reference) do
    case Repo.get_by(Payment, paystack_reference: reference, user_id: user.id) do
      nil ->
        {:error, :not_found}

      payment ->
        with {:ok, %{"status" => status} = data} <- PaystackClient.verify_transaction(reference) do
          case status do
            "success" ->
              handle_paystack_event("charge.success", data)

            status when status in ~w(pending queued ongoing processing) ->
              {:error, :pending}

            status ->
              mark_payment_terminal_failure(payment, status)
              {:error, :failed}
          end
        end
    end
  end

  defp mark_payment_terminal_failure(%Payment{status: "pending"} = payment, paystack_status) do
    our_status = if paystack_status == "abandoned", do: "abandoned", else: "failed"
    payment |> Payment.changeset(%{"status" => our_status}) |> Repo.update()
  end

  defp mark_payment_terminal_failure(_payment, _paystack_status), do: :ok

  defp generate_reference(user), do: "nurseprep-#{user.id}-#{System.system_time(:millisecond)}"

  defp create_pending_payment(user, reference) do
    %Payment{}
    |> Payment.changeset(%{
      "user_id" => user.id,
      "paystack_reference" => reference,
      "amount_kobo" => @plan_amount_kobo,
      "status" => "pending"
    })
    |> Repo.insert()
  end

  @doc """
  Processes one Paystack webhook event, idempotently (safe to call more
  than once for the same event-Paystack retries webhook delivery).
  """
  def handle_paystack_event(event_type, data) do
    idempotency_key = "#{event_type}:#{data["reference"] || data["id"] || Ecto.UUID.generate()}"

    case %PaystackEvent{}
         |> PaystackEvent.changeset(%{
           "idempotency_key" => idempotency_key,
           "event_type" => event_type,
           "payload" => data
         })
         |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, %{id: nil}} ->
        :already_processed

      {:ok, event} ->
        result = process_event(event_type, data)

        event
        |> PaystackEvent.changeset(%{
          "status" => "processed",
          "processed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

        result
    end
  end

  defp process_event("charge.success", %{"reference" => reference} = data) do
    case Repo.get_by(Payment, paystack_reference: reference) do
      nil ->
        {:error, :payment_not_found}

      %{status: "success"} ->
        :already_processed

      payment ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          {:ok, payment} =
            payment
            |> Payment.changeset(%{"status" => "success", "paid_at" => now})
            |> Repo.update()

          {:ok, subscription} = upsert_active_subscription(payment.user_id, now, data)

          {:ok, _} =
            payment |> Payment.changeset(%{"subscription_id" => subscription.id}) |> Repo.update()

          subscription
        end)
    end
  end

  defp process_event(event_type, %{"reference" => reference})
       when event_type in ["subscription.disable", "invoice.payment_failed"] do
    case Repo.get_by(Payment, paystack_reference: reference) do
      nil -> {:error, :payment_not_found}
      payment -> expire_subscription(payment.user_id)
    end
  end

  defp process_event(_event_type, _data), do: :ignored

  defp upsert_active_subscription(user_id, now, data) do
    existing = Repo.get_by(Subscription, user_id: user_id)
    {period_start, extend_from} = renewal_window(existing, now)
    period_end = DateTime.add(extend_from, @period_days * 24 * 60 * 60, :second)

    attrs = %{
      "user_id" => user_id,
      "status" => "active",
      "current_period_start" => period_start,
      "current_period_end" => period_end,
      "paystack_customer_code" => get_in(data, ["customer", "customer_code"])
    }

    case existing do
      nil -> %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert()
      existing -> existing |> Subscription.changeset(attrs) |> Repo.update()
    end
  end

  # A payment that lands while the user still has unexpired active time left
  # (an early renewal) stacks the new period on top of what's left, rather
  # than discarding it-otherwise paying a day before expiry would net the
  # user only one extra day instead of a full period. `period_start` is
  # preserved as the start of the ongoing active streak; only `period_end`
  # moves.
  defp renewal_window(
         %Subscription{status: "active", current_period_end: %DateTime{} = end_at} = existing,
         now
       ) do
    if DateTime.compare(end_at, now) == :gt do
      {existing.current_period_start, end_at}
    else
      {now, now}
    end
  end

  defp renewal_window(_existing, now), do: {now, now}

  defp expire_subscription(user_id) do
    case Repo.get_by(Subscription, user_id: user_id) do
      nil ->
        {:error, :subscription_not_found}

      subscription ->
        subscription |> Subscription.changeset(%{"status" => "expired"}) |> Repo.update()
    end
  end

  def cancel_subscription(%Subscription{} = subscription) do
    subscription |> Subscription.changeset(%{"cancel_at_period_end" => true}) |> Repo.update()
  end

  @doc "All subscriptions, newest first, for admin oversight-optionally filtered by status."
  def list_subscriptions(filters \\ %{}) do
    Subscription
    |> then(fn q ->
      if status = filters[:status], do: where(q, [s], s.status == ^status), else: q
    end)
    |> order_by(desc: :inserted_at)
    |> preload(user: :profile)
    |> Repo.all()
  end

  @doc "Recent payments across every user, newest first-for the admin subscriptions page's activity feed."
  def list_recent_payments(limit \\ 20) do
    Payment
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "Count of currently active (unexpired) subscriptions-the admin dashboard's revenue-health KPI tile."
  def count_active do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(s in Subscription, where: s.status == "active" and s.current_period_end > ^now),
      :count
    )
  end

  @doc "Successful payments, newest-paid first-the admin dashboard's activity feed (unlike `list_recent_payments/1`, excludes pending/failed/abandoned attempts nobody needs surfaced there)."
  def list_recent_successful_payments(limit \\ 5) do
    Payment
    |> where([p], p.status == "success")
    |> order_by(desc: :paid_at)
    |> limit(^limit)
    |> preload(user: :profile)
    |> Repo.all()
  end

  @doc """
  Support-desk override: grants (or extends) `days` of active access to
  `user` without a Paystack charge-for cases where a webhook was missed
  or a payment was confirmed out-of-band. Not tied to a real payment row,
  unlike the normal `charge.success` path.
  """
  def grant_manual_subscription(user, days \\ 90) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing = Repo.get_by(Subscription, user_id: user.id)
    {period_start, extend_from} = renewal_window(existing, now)
    period_end = DateTime.add(extend_from, days * 24 * 60 * 60, :second)

    attrs = %{
      "user_id" => user.id,
      "status" => "active",
      "current_period_start" => period_start,
      "current_period_end" => period_end
    }

    case existing do
      nil -> %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert()
      existing -> existing |> Subscription.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Support-desk override: immediately expires a user's active subscription."
  def revoke_subscription(user), do: expire_subscription(user.id)
end
