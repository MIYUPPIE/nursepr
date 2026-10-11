defmodule NursePrepWeb.SubscriptionLive do
  use NursePrepWeb, :live_view

  alias NursePrep.{Formatting, Subscriptions}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:subscription}>
      <.header icon="hero-banknotes">
        Subscription
        <:subtitle>
          {if @active?,
            do: "You're on Premium.",
            else: "Free tier: #{@daily_limit} practice questions/day, no timed mock exams."}
        </:subtitle>
      </.header>

      <div class={[
        "card mt-4 max-w-md",
        if(@active?,
          do: "bg-gradient-to-br from-success/15 to-success/5 border border-success/30",
          else: "bg-gradient-to-br from-primary/10 to-primary/5 border border-primary/20"
        )
      ]}>
        <div class="card-body">
          <%= if @active? do %>
            <div class="flex items-center gap-2 text-success font-semibold">
              <.icon name="hero-check-badge" class="size-5" /> Premium active
            </div>
            <p class="mt-1">
              Active until <strong>{Calendar.strftime(@subscription.current_period_end, "%B %d, %Y")}</strong>.
            </p>
            <p class="text-sm text-base-content/60 mt-1">
              Unlimited practice, timed mock exams, and the AI tutor are all unlocked.
            </p>
          <% else %>
            <p class="text-3xl font-extrabold">
              ₦{Formatting.naira(@amount_kobo)}<span class="text-sm font-normal text-base-content/60">/quarter</span>
            </p>
            <ul class="text-sm mt-3 space-y-2">
              <li class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-4 text-primary shrink-0" />
                Unlimited practice questions
              </li>
              <li class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-4 text-primary shrink-0" />
                Timed NMCN-format mock exams
              </li>
              <li class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-4 text-primary shrink-0" /> AI tutor
              </li>
            </ul>
            <.button
              variant="primary"
              phx-click="upgrade"
              phx-disable-with="Redirecting..."
              class="mt-4 w-full"
            >
              Upgrade to Premium
            </.button>
          <% end %>
        </div>
      </div>

      <.section :if={@payments != []} title="Payment history">
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Date</th>
                <th>Amount</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @payments}>
                <td>{Calendar.strftime(p.inserted_at, "%Y-%m-%d")}</td>
                <td>₦{Formatting.naira(p.amount_kobo)}</td>
                <td><.status_badge status={p.status} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </.section>
    </Layouts.student>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     assign(socket,
       active?: Subscriptions.active?(user),
       subscription: Subscriptions.get_active_subscription(user),
       amount_kobo: Subscriptions.plan_amount_kobo(),
       daily_limit: Subscriptions.free_daily_practice_limit(),
       payments: Subscriptions.list_payments(user)
     )}
  end

  @impl true
  def handle_event("upgrade", _params, socket) do
    case Subscriptions.checkout_url(socket.assigns.current_scope.user) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Payments aren't available right now-please try again shortly."
         )}
    end
  end
end
