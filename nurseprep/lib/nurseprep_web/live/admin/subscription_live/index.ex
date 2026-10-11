defmodule NursePrepWeb.Admin.SubscriptionLive.Index do
  @moduledoc """
  Payments/subscriptions oversight, plus a manual entitlement override for
  support cases where a Paystack webhook was missed or a payment was
  confirmed out-of-band. Admin-only, same reasoning as `Admin.UserLive`.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Accounts, Formatting, Subscriptions}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:subscriptions}>
      <.header icon="hero-banknotes">
        Subscriptions
        <:subtitle>Entitlement oversight and manual overrides for support cases.</:subtitle>
      </.header>

      <div class="card bg-base-100 border border-base-300 my-4">
        <div class="card-body">
          <h3 class="font-semibold mb-2 flex items-center gap-2">
            <.icon name="hero-hand-raised" class="size-4 text-primary" /> Manual grant
          </h3>
          <p class="text-sm text-base-content/60 mb-2">
            For confirmed out-of-band payments or a missed webhook-bypasses Paystack entirely.
          </p>
          <form id="manual-grant-form" phx-submit="grant" class="flex gap-2 flex-wrap items-end">
            <input
              type="text"
              name="identifier"
              placeholder="+2348012345678 or email"
              class="input input-bordered input-sm"
              required
            />
            <input
              type="number"
              name="days"
              value="90"
              min="1"
              class="input input-bordered input-sm w-24"
            />
            <.button variant="primary" class="btn-sm" phx-disable-with="Granting...">
              Grant access
            </.button>
          </form>
        </div>
      </div>

      <div class="flex gap-2 my-4 flex-wrap">
        <button
          :for={status <- ~w(active pending expired cancelled)}
          phx-click="filter_status"
          phx-value-status={status}
          class={["btn btn-sm", @status == status && "btn-primary"]}
        >
          {String.capitalize(status)}
        </button>
        <button
          phx-click="filter_status"
          phx-value-status=""
          class={["btn btn-sm", @status == nil && "btn-primary"]}
        >
          All
        </button>
      </div>

      <.empty_state :if={@subscriptions == []} icon="hero-banknotes">
        No subscriptions{if @status, do: " with status \"#{@status}\""} yet.
      </.empty_state>

      <.table :if={@subscriptions != []} id="subscriptions" rows={@subscriptions}>
        <:col :let={s} label="Contact">{NursePrep.Accounts.User.identifier(s.user)}</:col>
        <:col :let={s} label="Name">{(s.user.profile && s.user.profile.full_name) || "—"}</:col>
        <:col :let={s} label="Plan">{s.plan}</:col>
        <:col :let={s} label="Status">
          <.status_badge status={s.status} />
        </:col>
        <:col :let={s} label="Period end">
          {s.current_period_end && Calendar.strftime(s.current_period_end, "%Y-%m-%d")}
        </:col>
        <:action :let={s}>
          <.link
            :if={s.status == "active"}
            phx-click="revoke"
            phx-value-user_id={s.user_id}
            data-confirm="Revoke this user's access now?"
            class="link link-error text-sm"
          >
            Revoke
          </.link>
        </:action>
      </.table>

      <.section title="Recent payments">
        <.empty_state :if={@payments == []} icon="hero-credit-card">
          No payments yet.
        </.empty_state>
        <.table :if={@payments != []} id="payments" rows={@payments}>
          <:col :let={p} label="Contact">{NursePrep.Accounts.User.identifier(p.user)}</:col>
          <:col :let={p} label="Reference"><code class="text-xs">{p.paystack_reference}</code></:col>
          <:col :let={p} label="Amount">₦{Formatting.naira(p.amount_kobo)}</:col>
          <:col :let={p} label="Status">
            <.status_badge status={p.status} />
          </:col>
          <:col :let={p} label="Paid at">
            {p.paid_at && Calendar.strftime(p.paid_at, "%Y-%m-%d %H:%M")}
          </:col>
        </.table>
      </.section>
    </Layouts.admin>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: nil)
     |> load_subscriptions()
     |> assign(payments: Subscriptions.list_recent_payments())}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, socket |> assign(status: status) |> load_subscriptions()}
  end

  def handle_event("grant", %{"identifier" => identifier, "days" => days}, socket) do
    case find_user_by_identifier(identifier) do
      nil ->
        {:noreply, put_flash(socket, :error, "No user found with #{identifier}.")}

      user ->
        {:ok, _} = Subscriptions.grant_manual_subscription(user, String.to_integer(days))

        {:noreply,
         socket
         |> load_subscriptions()
         |> put_flash(:info, "Granted #{days} days of access to #{identifier}.")}
    end
  end

  def handle_event("revoke", %{"user_id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    {:ok, _} = Subscriptions.revoke_subscription(user)

    {:noreply,
     socket
     |> load_subscriptions()
     |> put_flash(:info, "Revoked access for #{NursePrep.Accounts.User.identifier(user)}.")}
  end

  defp find_user_by_identifier(identifier) do
    case NursePrep.Accounts.PhoneNumber.normalize(identifier) do
      {:ok, phone} -> Accounts.get_user_by_phone(phone)
      {:error, _} -> nil
    end ||
      case NursePrep.Accounts.Email.normalize(identifier) do
        {:ok, email} -> Accounts.get_user_by_email(email)
        {:error, _} -> nil
      end
  end

  defp load_subscriptions(socket) do
    filters = if socket.assigns.status, do: %{status: socket.assigns.status}, else: %{}
    assign(socket, subscriptions: Subscriptions.list_subscriptions(filters))
  end
end
