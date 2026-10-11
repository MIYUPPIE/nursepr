defmodule NursePrepWeb.AnalyticsLive do
  @moduledoc """
  Per-topic accuracy breakdown, readiness trend, and a direct CTA into
  practice for whichever topic is weakest-the drill-down a dashboard
  summary card can't fit.
  """
  use NursePrepWeb, :live_view

  alias NursePrep.{Analytics, Formatting}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:analytics}>
      <.header icon="hero-chart-bar">
        Your analytics
        <:subtitle>Where you stand, topic by topic.</:subtitle>
      </.header>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mt-4">
        <.stat_card
          icon="hero-chart-bar"
          label="Readiness score"
          value={Formatting.percent(@readiness_score)}
          accent={readiness_accent(@readiness_score)}
        />
        <.stat_card
          icon="hero-bolt"
          label="Current streak"
          value={"#{@streak} day#{if @streak != 1, do: "s"}"}
          accent={@streak > 0 && "text-warning"}
        />
        <.stat_card icon="hero-book-open" label="Topics tracked" value={"#{length(@topic_accuracy)}"} />
      </div>

      <div :if={@weak_areas != []} class="alert alert-warning mt-6">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          Weakest right now: <span class="font-semibold">{hd(@weak_areas).topic_name}</span>
          at {Formatting.percent(hd(@weak_areas).accuracy)}.
          <.link
            navigate={~p"/practice?topic_id=#{hd(@weak_areas).topic_id}"}
            class="link font-semibold"
          >
            Drill it now →
          </.link>
          ·
          <.link navigate={~p"/tutor?explain=weak_areas"} class="link font-semibold">
            Ask AI to explain →
          </.link>
        </span>
      </div>

      <.section title="Accuracy by topic">
        <.empty_state :if={@topic_accuracy == []} icon="hero-chart-bar-square">
          Answer a few practice questions and your topic breakdown will show up here.
        </.empty_state>
        <div class="space-y-2">
          <div
            :for={row <- @topic_accuracy}
            class="flex items-center gap-2 sm:gap-3 p-2 rounded-lg hover:bg-base-200 transition-colors"
          >
            <span class="w-20 sm:w-40 shrink-0 text-xs sm:text-sm truncate" title={row.topic_name}>
              {row.topic_name}
            </span>
            <div class="flex-1 h-4 rounded-full bg-base-300 overflow-hidden">
              <div
                class={["h-full rounded-full transition-all", bar_color(row.accuracy)]}
                style={"width: #{row.accuracy}%"}
              />
            </div>
            <span class="w-16 sm:w-24 shrink-0 text-xs sm:text-sm text-right text-base-content/70">
              {Formatting.percent(row.accuracy)} · {row.attempts}
            </span>
          </div>
        </div>
      </.section>
    </Layouts.student>
    """
  end

  defp bar_color(accuracy) when accuracy >= 70.0, do: "bg-success"
  defp bar_color(accuracy) when accuracy >= 50.0, do: "bg-warning"
  defp bar_color(_accuracy), do: "bg-error"

  defp readiness_accent(nil), do: nil
  defp readiness_accent(score) when score >= 70, do: "text-success"
  defp readiness_accent(score) when score >= 40, do: "text-warning"
  defp readiness_accent(_score), do: "text-error"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     assign(socket,
       readiness_score: Analytics.readiness_score(user),
       streak: Analytics.streak(user),
       weak_areas: Analytics.weak_areas(user, 1),
       topic_accuracy: Analytics.topic_accuracy(user)
     )}
  end
end
