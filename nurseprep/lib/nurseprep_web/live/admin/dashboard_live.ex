defmodule NursePrepWeb.Admin.DashboardLive do
  @moduledoc """
  Admin home: question-pipeline KPIs, a "needs attention" breakdown of the
  pending review queue by type, and a merged recent-activity feed.

  The activity feed and two of the KPI tiles (`students`, `active
  subscriptions`) surface PII/financial data, so-mirroring the router's
  `:admin_strict` gate on `/admin/users` and `/admin/subscriptions`-they're
  only assembled and rendered for `role == "admin"`, never for a
  `reviewer`. `mount/3` skips the underlying queries entirely for a
  reviewer rather than fetching and merely hiding them in the template.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Accounts, Formatting, Questions, Subscriptions}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <.header icon="hero-squares-2x2">
        Dashboard
        <:subtitle>
          Signed in as {NursePrep.Accounts.User.identifier(@current_scope.user)} ({@current_scope.user.role})
        </:subtitle>
      </.header>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mt-4">
        <.stat_tile
          label="Pending reviews"
          value={@stats.pending_reviews}
          navigate={~p"/admin/review-queue"}
          icon="hero-inbox-stack"
          accent="text-warning"
        />
        <.stat_tile
          label="Published questions"
          value={@stats.published_questions}
          navigate={~p"/admin/questions"}
          icon="hero-check-circle"
          accent="text-success"
        />
        <.stat_tile
          label="Draft questions"
          value={@stats.draft_questions}
          navigate={~p"/admin/questions"}
          icon="hero-document-text"
          accent="text-base-content/50"
        />
        <.stat_tile
          label="Flagged"
          value={@stats.flagged_questions}
          navigate={~p"/admin/questions"}
          icon="hero-flag"
          accent="text-error"
        />
      </div>

      <div :if={@current_scope.user.role == "admin"} class="grid grid-cols-2 gap-4 mt-4 max-w-md">
        <.stat_tile
          label="Students"
          value={@stats.students}
          navigate={~p"/admin/users"}
          icon="hero-user-group"
          accent="text-primary"
        />
        <.stat_tile
          label="Active subscriptions"
          value={@stats.active_subscriptions}
          navigate={~p"/admin/subscriptions"}
          icon="hero-banknotes"
          accent="text-success"
        />
      </div>

      <.section :if={@review_breakdown != []} title="Needs attention">
        <div class="space-y-2">
          <.link
            :for={row <- @review_breakdown}
            navigate={~p"/admin/review-queue?type=#{row.review_type}"}
            class="flex items-center justify-between p-3 rounded-lg bg-base-100 border border-base-300 hover:border-warning transition-colors"
          >
            <span class="flex items-center gap-2">
              <.icon name={review_type_icon(row.review_type)} class="size-4 text-base-content/50" />
              {humanize(row.review_type)}
            </span>
            <span class="badge badge-warning">{row.count} pending</span>
          </.link>
        </div>
      </.section>

      <.section title="Recent activity">
        <ul :if={@activity != []} class="space-y-1">
          <li :for={event <- @activity}>
            <.link
              navigate={event.navigate}
              class="flex items-center gap-3 p-2 rounded-lg bg-base-100 border border-base-300 hover:border-primary transition-colors"
            >
              <span class={[
                "flex size-8 shrink-0 items-center justify-center rounded-full bg-current/10",
                event.accent
              ]}>
                <.icon name={event.icon} class="size-4" />
              </span>
              <span class="flex-1 text-sm">{event.text}</span>
              <span class="text-xs text-base-content/50 shrink-0">
                {Formatting.relative_time(event.at)}
              </span>
            </.link>
          </li>
        </ul>
        <.empty_state :if={@activity == []} icon="hero-clock">
          Nothing here yet-review decisions and signups will show up as they happen.
        </.empty_state>
      </.section>
    </Layouts.admin>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :accent, :string, required: true

  defp stat_tile(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="card bg-base-100 border border-base-300 hover:border-primary transition-colors"
    >
      <div class="card-body p-4">
        <div class={[
          "flex size-8 items-center justify-center rounded-full bg-current/10 mb-1",
          @accent
        ]}>
          <.icon name={@icon} class="size-4" />
        </div>
        <p class="text-xs uppercase tracking-wide text-base-content/60">{@label}</p>
        <p class="text-3xl font-bold">{@value}</p>
      </div>
    </.link>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    role = socket.assigns.current_scope.user.role

    {:ok,
     assign(socket,
       stats: dashboard_stats(role),
       review_breakdown: Questions.pending_reviews_by_type(),
       activity: activity_feed(role)
     )}
  end

  defp dashboard_stats(role) do
    base = Questions.admin_dashboard_stats()

    if role == "admin" do
      Map.merge(base, %{
        students: Accounts.count_students(),
        active_subscriptions: Subscriptions.count_active()
      })
    else
      base
    end
  end

  defp activity_feed(role) do
    review_events = Enum.map(Questions.recent_review_decisions(8), &review_event/1)

    admin_events =
      if role == "admin" do
        Enum.map(Accounts.list_recent_signups(5), &signup_event/1) ++
          Enum.map(Subscriptions.list_recent_successful_payments(5), &payment_event/1)
      else
        []
      end

    (review_events ++ admin_events)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(10)
  end

  defp review_event(review) do
    approved? = review.status == "approved"

    %{
      at: review.updated_at,
      icon: if(approved?, do: "hero-check-circle", else: "hero-x-circle"),
      accent: if(approved?, do: "text-success", else: "text-error"),
      text: "#{staff_name(review.reviewer)} #{review.status} “#{excerpt(review.question.stem)}”",
      navigate: ~p"/admin/questions/#{review.question_id}"
    }
  end

  defp signup_event(user) do
    %{
      at: user.inserted_at,
      icon: "hero-user-plus",
      accent: "text-info",
      text: "#{student_name(user)} signed up",
      navigate: ~p"/admin/users"
    }
  end

  defp payment_event(payment) do
    %{
      at: payment.paid_at,
      icon: "hero-banknotes",
      accent: "text-success",
      text: "#{student_name(payment.user)} paid ₦#{Formatting.naira(payment.amount_kobo)}",
      navigate: ~p"/admin/subscriptions"
    }
  end

  defp staff_name(nil), do: "Someone"
  defp staff_name(user), do: NursePrep.Accounts.User.identifier(user)

  defp student_name(%{profile: %{full_name: name}}) when is_binary(name), do: name
  defp student_name(user), do: NursePrep.Accounts.User.identifier(user)

  @excerpt_length 60

  defp excerpt(stem) when byte_size(stem) > @excerpt_length,
    do: String.slice(stem, 0, @excerpt_length) <> "…"

  defp excerpt(stem), do: stem

  defp review_type_icon("ingestion_cleanup"), do: "hero-sparkles"
  defp review_type_icon("tagging"), do: "hero-tag"
  defp review_type_icon("explanation"), do: "hero-light-bulb"
  defp review_type_icon("flagged_image"), do: "hero-photo"
  defp review_type_icon("flagged_malformed"), do: "hero-exclamation-triangle"
  defp review_type_icon(_), do: "hero-question-mark-circle"

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")
end
