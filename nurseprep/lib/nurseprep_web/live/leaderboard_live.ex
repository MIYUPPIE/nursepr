defmodule NursePrepWeb.LeaderboardLive do
  @moduledoc """
  Weekly and all-time rankings by correct answers. Subscribes to the
  `"leaderboard"` PubSub topic (broadcast from `Quizzes.submit_session/2`
  on every completed session) so ranks update live across connected
  students without a manual refresh.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.Analytics

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:leaderboard}>
      <.header icon="hero-trophy">
        Leaderboard
        <:subtitle>Ranked by correct answers. Updates live.</:subtitle>
      </.header>

      <div class="tabs tabs-boxed w-fit mt-4 bg-base-200">
        <button
          type="button"
          phx-click="scope"
          phx-value-scope="weekly"
          class={["tab", @scope == :weekly && "tab-active !bg-primary !text-primary-content"]}
        >
          This week
        </button>
        <button
          type="button"
          phx-click="scope"
          phx-value-scope="all_time"
          class={["tab", @scope == :all_time && "tab-active !bg-primary !text-primary-content"]}
        >
          All time
        </button>
      </div>

      <.empty_state :if={@board == []} icon="hero-trophy" class="mt-6">
        No ranked activity yet{if @scope == :weekly, do: " this week"}.
      </.empty_state>

      <ol :if={@board != []} class="mt-6 space-y-1.5">
        <li
          :for={{row, i} <- Enum.with_index(@board, 1)}
          class={[
            "flex items-center justify-between p-3 rounded-lg border transition-colors",
            row.user_id == @current_scope.user.id && "border-primary bg-primary/5",
            row.user_id != @current_scope.user.id && "border-base-300 bg-base-100"
          ]}
        >
          <span class="flex items-center gap-3">
            <span class={[
              "w-8 h-8 flex items-center justify-center rounded-full text-center font-bold text-sm",
              i <= 3 && "text-lg",
              i > 3 && "bg-base-200 text-base-content/60"
            ]}>
              {medal(i)}
            </span>
            <span class="font-medium">{row.name || "Student"}</span>
          </span>
          <span class="text-sm text-base-content/70">
            {row.correct}/{row.answered} correct
          </span>
        </li>
      </ol>

      <p class="text-sm text-base-content/60 mt-6">
        Don't want to appear here? <.link navigate={~p"/users/settings"} class="link">Turn it off in your profile</.link>.
      </p>
    </Layouts.student>
    """
  end

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(n), do: "#{n}"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NursePrep.PubSub, "leaderboard")
    end

    {:ok, assign(socket, scope: :weekly, board: Analytics.leaderboard(:weekly))}
  end

  @impl true
  def handle_event("scope", %{"scope" => scope}, socket) do
    scope = String.to_existing_atom(scope)
    {:noreply, assign(socket, scope: scope, board: Analytics.leaderboard(scope))}
  end

  @impl true
  def handle_info(:leaderboard_updated, socket) do
    {:noreply, assign(socket, board: Analytics.leaderboard(socket.assigns.scope))}
  end
end
