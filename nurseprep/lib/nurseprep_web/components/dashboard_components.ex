defmodule NursePrepWeb.DashboardComponents do
  @moduledoc """
  Function components for the student dashboard (`NursePrepWeb.DashboardLive`)
  only-imported explicitly there rather than added to `NursePrepWeb`'s
  global `html_helpers/0` the way `CoreComponents` is, since these are
  dashboard-specific composites, not generic building blocks every page
  needs.
  """
  use NursePrepWeb, :html

  alias NursePrep.Formatting

  ## Readiness hero

  @doc "The dashboard's lead widget: a readiness ring plus the single next recommended action."
  attr :score, :integer, default: nil
  attr :answered, :integer, required: true
  attr :next_label, :string, required: true
  attr :next_path, :string, required: true

  def readiness_hero(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-gradient-to-br from-primary/10 via-primary/5 to-transparent border border-primary/15 overflow-hidden">
      <div class="card-body p-6 sm:p-8">
        <div class="flex flex-col sm:flex-row items-center sm:items-start gap-6 sm:gap-10">
          <div class="shrink-0 flex flex-col items-center gap-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Your Exam Readiness
            </p>
            <div
              class="progress-ring size-36 sm:size-40"
              style={"--ring-pct: #{@score || 0}; --ring-color: var(--color-#{ring_accent(@score)})"}
              role="progressbar"
              aria-valuenow={@score || 0}
              aria-valuemin="0"
              aria-valuemax="100"
              aria-label="Exam readiness"
            >
              <div class="flex flex-col items-center">
                <span class="text-4xl font-extrabold tabular-nums">
                  <span
                    id="readiness-count"
                    phx-hook="CountUp"
                    data-count-to={@score || 0}
                    data-count-suffix="%"
                  >
                    0%
                  </span>
                </span>
                <span class="text-xs font-medium text-base-content/50">Exam Ready</span>
              </div>
            </div>
            <p class="text-xs text-base-content/50 text-center max-w-56">
              <%= if @answered > 0 do %>
                You've completed
                <span class="font-semibold text-base-content/70">{@score || 0}%</span>
                of your recommended preparation.
              <% else %>
                Answer a few questions to unlock your readiness score.
              <% end %>
            </p>
          </div>

          <div class="flex-1 w-full min-w-0">
            <div class="flex items-center justify-between mb-1">
              <p class="text-sm font-semibold text-base-content/70">Preparation progress</p>
              <p class="text-sm font-semibold">{@score || 0}%</p>
            </div>
            <progress
              class={["progress w-full", progress_color(@score)]}
              value={@score || 0}
              max="100"
            />

            <div class="mt-6 p-4 rounded-2xl bg-base-100/70 border border-base-300">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
                Recommended next step
              </p>
              <p class="font-medium">{@next_label}</p>
            </div>

            <div class="flex flex-col sm:flex-row sm:flex-wrap gap-3 mt-5">
              <.link navigate={@next_path} class="btn btn-primary rounded-full flex-1 sm:flex-none">
                Continue Studying
              </.link>
              <.link navigate={~p"/analytics"} class="btn btn-ghost rounded-full flex-1 sm:flex-none">
                View Full Analysis
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp ring_accent(nil), do: "neutral"
  defp ring_accent(score) when score >= 70, do: "success"
  defp ring_accent(score) when score >= 40, do: "warning"
  defp ring_accent(_score), do: "error"

  defp progress_color(nil), do: nil
  defp progress_color(score) when score >= 70, do: "progress-success"
  defp progress_color(score) when score >= 40, do: "progress-warning"
  defp progress_color(_score), do: "progress-error"

  ## Today's study plan

  @doc "Up to 3-4 actionable \"what should I do today\" cards, each built by `DashboardLive`."
  attr :cards, :list, required: true

  def study_plan(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <div :for={c <- @cards} class="card rounded-3xl bg-base-100 border border-base-300">
        <div class="card-body p-5">
          <div class="flex items-center gap-2">
            <span class={[
              "flex size-8 items-center justify-center rounded-full bg-current/10",
              c[:accent] || "text-primary"
            ]}>
              <.icon name={c.icon} class="size-4" />
            </span>
            <h4 class="font-semibold text-sm">{c.title}</h4>
          </div>
          <p class="text-sm text-base-content/70 mt-2">{c.description}</p>

          <div :if={c[:progress]} class="mt-3">
            <progress
              class="progress progress-primary w-full"
              value={elem(c.progress, 0)}
              max={elem(c.progress, 1)}
            />
            <p class="text-xs text-base-content/50 mt-1">
              {elem(c.progress, 0)}/{elem(c.progress, 1)} complete
            </p>
          </div>

          <.link
            navigate={c.cta_path}
            class={["btn btn-sm rounded-full w-full mt-4", (c[:done] && "btn-ghost") || "btn-primary"]}
          >
            {c.cta_label}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  ## Performance overview

  @doc """
  One KPI tile with an optional signed delta badge and/or a plain note
  (e.g. "Longest: 21 days"). `count_to`/`count_suffix` drive the count-up
  animation when the value is a plain number (e.g. `87` + `"%"`); leave
  `count_to` `nil` for a value that isn't a clean count-up (e.g. "—" when
  there's no mock-exam attempt yet) and `@value` renders statically.
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :count_to, :integer, default: nil
  attr :count_suffix, :string, default: ""
  attr :delta, :any, default: nil
  attr :delta_label, :string, default: ""
  attr :note, :string, default: nil

  def overview_stat(assigns) do
    ~H"""
    <div class="card rounded-2xl bg-base-100 border border-base-300">
      <div class="card-body p-4 sm:p-5 gap-1.5">
        <div class="flex items-center justify-between">
          <span class="flex size-8 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name={@icon} class="size-4" />
          </span>
          <span
            :if={@delta && @delta != 0}
            class={[
              "badge badge-sm gap-1",
              (@delta >= 0 && "badge-success badge-soft") || "badge-error badge-soft"
            ]}
          >
            <.icon
              name={(@delta >= 0 && "hero-arrow-trending-up") || "hero-arrow-trending-down"}
              class="size-3"
            />
            {abs(@delta)}{@delta_label}
          </span>
        </div>
        <p class="text-2xl sm:text-3xl font-extrabold tabular-nums mt-1">
          <span
            :if={@count_to}
            id={@id}
            phx-hook="CountUp"
            data-count-to={@count_to}
            data-count-suffix={@count_suffix}
          >
            0{@count_suffix}
          </span>
          <span :if={!@count_to}>{@value}</span>
        </p>
        <p class="text-xs uppercase tracking-wide text-base-content/50">{@label}</p>
        <p :if={@note} class="text-xs text-base-content/60 mt-0.5">{@note}</p>
      </div>
    </div>
    """
  end

  ## Performance chart

  @doc "Switchable-metric line chart (accuracy / questions / study time) over a switchable time range-hand-rolled inline SVG, no JS chart library."
  attr :series, :list, required: true
  attr :metric, :atom, required: true
  attr :range, :atom, required: true

  def performance_chart(assigns) do
    assigns = assign(assigns, :geometry, chart_geometry(assigns.series, assigns.metric))

    ~H"""
    <div class="card rounded-3xl bg-base-100 border border-base-300">
      <div class="card-body p-5 sm:p-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div>
            <h3 class="font-semibold">Your Performance</h3>
            <p class="text-sm text-base-content/60">{metric_description(@metric)}</p>
          </div>
          <div class="join">
            <button
              :for={{label, value} <- range_options()}
              type="button"
              phx-click="chart_range"
              phx-value-range={value}
              class={["btn btn-xs join-item", (@range == value && "btn-primary") || "btn-ghost"]}
            >
              {label}
            </button>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 mt-4">
          <button
            :for={{label, value} <- metric_options()}
            type="button"
            phx-click="chart_metric"
            phx-value-metric={value}
            class={[
              "btn btn-xs rounded-full",
              (@metric == value && "btn-primary") || "btn-ghost border border-base-300"
            ]}
          >
            {label}
          </button>
        </div>

        <.empty_state :if={@geometry.segments == []} icon="hero-chart-bar-square" class="py-10">
          Practice a little to see your trend here.
        </.empty_state>

        <svg
          :if={@geometry.segments != []}
          viewBox={"0 0 #{@geometry.width} #{@geometry.height}"}
          preserveAspectRatio="none"
          class="w-full h-44 mt-4"
          role="img"
          aria-label={"#{metric_description(@metric)} chart"}
        >
          <polyline
            :for={seg <- @geometry.segments}
            points={Enum.map_join(seg, " ", &"#{Float.round(&1.x, 1)},#{Float.round(&1.y, 1)}")}
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            vector-effect="non-scaling-stroke"
          />
          <circle
            :for={p <- Enum.reject(@geometry.points, &is_nil(&1.y))}
            cx={Float.round(p.x, 1)}
            cy={Float.round(p.y, 1)}
            r="3.5"
            fill="var(--color-primary)"
          >
            <title>
              {Calendar.strftime(p.date, "%b %d")}: {format_metric_label(p.value, @metric)}
            </title>
          </circle>
        </svg>
      </div>
    </div>
    """
  end

  defp range_options,
    do: [{"7 Days", :days_7}, {"30 Days", :days_30}, {"90 Days", :days_90}, {"All Time", :all}]

  defp metric_options,
    do: [{"Accuracy", :accuracy}, {"Questions", :answered}, {"Study Time", :study_minutes}]

  defp metric_description(:accuracy), do: "Accuracy over time"
  defp metric_description(:answered), do: "Questions completed over time"
  defp metric_description(:study_minutes), do: "Study time over time"

  defp format_metric_label(nil, _metric), do: "No data"
  defp format_metric_label(value, :accuracy), do: "#{trunc(value)}%"
  defp format_metric_label(value, :answered), do: "#{value} question#{if value != 1, do: "s"}"
  defp format_metric_label(value, :study_minutes), do: "#{value} min"

  defp chart_geometry(series, metric) do
    width = 600
    height = 200
    padding_y = 16
    plot_height = height - padding_y * 2
    n = length(series)
    max_value = metric_max(series, metric) * 1.15

    points =
      series
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        value = metric_value(row, metric)
        x = if n > 1, do: i / (n - 1) * width, else: width / 2
        y = value && padding_y + plot_height - value / max_value * plot_height

        %{x: x, y: y, date: row.date, value: value}
      end)

    segments =
      points
      |> Enum.chunk_by(&is_nil(&1.y))
      |> Enum.reject(fn chunk -> is_nil(hd(chunk).y) end)

    %{points: points, segments: segments, width: width, height: height}
  end

  defp metric_value(row, :accuracy), do: row.accuracy
  defp metric_value(row, :answered), do: row.answered
  defp metric_value(row, :study_minutes), do: row.study_minutes

  defp metric_max(_series, :accuracy), do: 100

  defp metric_max(series, metric) do
    series
    |> Enum.map(&metric_value(&1, metric))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 1
      values -> values |> Enum.max() |> max(1)
    end
  end

  ## Subject performance

  @doc "Per-subject accuracy bars, mirroring `AnalyticsLive`'s per-topic bars one level up the taxonomy."
  attr :subjects, :list, required: true

  def subject_bars(assigns) do
    ~H"""
    <.empty_state :if={@subjects == []} icon="hero-book-open">
      Practice a few questions and your subject breakdown will show up here.
    </.empty_state>
    <div :if={@subjects != []} class="divide-y divide-base-300">
      <div :for={row <- @subjects} class="py-3 first:pt-0 last:pb-0">
        <div class="flex items-center justify-between gap-3 mb-2">
          <span class="text-sm font-medium truncate" title={row.subject_name}>
            {row.subject_name}
          </span>
          <div class="flex items-center gap-3 shrink-0">
            <span class="text-sm font-semibold">{Formatting.percent(row.accuracy)}</span>
            <.link navigate={~p"/practice?subject_id=#{row.subject_id}"} class="btn btn-ghost btn-xs">
              Practice
            </.link>
          </div>
        </div>
        <div class="flex items-center gap-3">
          <div class="flex-1 h-2.5 rounded-full bg-base-300 overflow-hidden">
            <div
              class={["h-full rounded-full", accuracy_bar_color(row.accuracy)]}
              style={"width: #{row.accuracy}%"}
            />
          </div>
          <span class="w-14 shrink-0 text-xs text-base-content/50 text-right">
            {row.attempts} qs
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp accuracy_bar_color(accuracy) when accuracy >= 70.0, do: "bg-success"
  defp accuracy_bar_color(accuracy) when accuracy >= 50.0, do: "bg-warning"
  defp accuracy_bar_color(_accuracy), do: "bg-error"

  ## Weak / strong areas

  @doc "Side-by-side weak-area drill-down and strong-area recognition cards."
  attr :weak, :list, required: true
  attr :strong, :list, required: true

  def weak_strong_areas(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <div class="card rounded-3xl bg-base-100 border border-base-300">
        <div class="card-body p-5 sm:p-6">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-arrow-trending-down" class="size-4 text-warning" />
            Topics That Need Attention
          </h3>
          <p class="text-sm text-base-content/60 mt-0.5">
            Based on your recent performance, these topics need more practice.
          </p>

          <.empty_state :if={@weak == []} icon="hero-check-badge" class="py-8">
            No weak spots yet-keep practicing and we'll flag anything worth another look.
          </.empty_state>

          <div :if={@weak != []} class="space-y-2.5 mt-3">
            <div
              :for={w <- @weak}
              class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 sm:gap-3 p-3 rounded-2xl bg-warning/5 border border-warning/20"
            >
              <div class="min-w-0">
                <p class="font-medium">{w.topic_name}</p>
                <p class="text-xs text-base-content/60">
                  {Formatting.percent(w.accuracy)} accuracy · {w.attempts} attempts
                </p>
              </div>
              <.link
                navigate={~p"/practice?topic_id=#{w.topic_id}"}
                class="btn btn-warning btn-soft btn-sm shrink-0 self-start sm:self-auto"
              >
                Practice Now
              </.link>
            </div>
          </div>
        </div>
      </div>

      <div class="card rounded-3xl bg-base-100 border border-base-300">
        <div class="card-body p-5 sm:p-6">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-star" class="size-4 text-success" /> Your Strongest Topics
          </h3>

          <.empty_state :if={@strong == []} icon="hero-star" class="py-8">
            Keep practicing-your strongest topics will show up here once a few stand out.
          </.empty_state>

          <ul :if={@strong != []} class="space-y-2.5 mt-3">
            <li
              :for={s <- @strong}
              class="flex items-center justify-between gap-3 p-3 rounded-2xl bg-success/5 border border-success/20"
            >
              <span class="font-medium truncate">{s.topic_name}</span>
              <span class="badge badge-success badge-soft shrink-0">{Formatting.percent(s.accuracy)}</span>
            </li>
          </ul>

          <p :if={@strong != []} class="text-xs text-base-content/50 mt-3">
            Great work. Keep these topics fresh with occasional revision.
          </p>
        </div>
      </div>
    </div>
    """
  end

  ## Recent activity

  @doc "Timeline of recently completed sessions."
  attr :sessions, :list, required: true

  def activity_timeline(assigns) do
    ~H"""
    <.empty_state :if={@sessions == []} icon="hero-list-bullet">
      Your completed sessions will show up here.
    </.empty_state>
    <ul :if={@sessions != []} class="space-y-1">
      <li :for={s <- @sessions}>
        <.link
          navigate={~p"/sessions/#{s.id}/results"}
          class="flex items-center gap-3 p-3 rounded-2xl hover:bg-base-200 transition-colors"
        >
          <span class={[
            "flex size-9 shrink-0 items-center justify-center rounded-full bg-current/10",
            session_accent(s.mode)
          ]}>
            <.icon name={session_icon(s.mode)} class="size-4" />
          </span>
          <span class="flex-1 min-w-0">
            <span class="block font-medium truncate">{session_title(s)}</span>
            <span class="block text-xs text-base-content/50">
              {activity_group(s.completed_at)} · {s.question_count} questions
            </span>
          </span>
          <span class="font-semibold shrink-0">{s.score}/{s.question_count}</span>
          <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0" />
        </.link>
      </li>
    </ul>
    """
  end

  defp session_title(%{mode: "exam"}), do: "Mock exam"
  defp session_title(%{subject: %{name: name}}), do: name
  defp session_title(%{topic: %{name: name}}), do: name
  defp session_title(_session), do: "Practice session"

  defp activity_group(nil), do: "-"

  defp activity_group(at) do
    case Date.diff(Date.utc_today(), DateTime.to_date(at)) do
      0 -> "Today"
      1 -> "Yesterday"
      n when n < 7 -> Calendar.strftime(at, "%A")
      _n -> Calendar.strftime(at, "%b %d")
    end
  end

  defp session_icon("exam"), do: "hero-clock"
  defp session_icon(_mode), do: "hero-pencil-square"
  defp session_accent("exam"), do: "text-secondary"
  defp session_accent(_mode), do: "text-primary"

  ## Mock exam promo

  @doc "Prominent mock-exam CTA card-subscription-gated, never offers a start button a free user would then be blocked at."
  attr :format, :map, required: true
  attr :can_start, :boolean, required: true
  attr :latest_exam, :map, default: nil
  attr :readiness_score, :integer, default: nil

  def mock_exam_promo(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-gradient-to-br from-secondary/10 via-secondary/5 to-transparent border border-secondary/20">
      <div class="card-body p-5 sm:p-6">
        <div class="flex items-center gap-2">
          <span class="flex size-9 items-center justify-center rounded-full bg-secondary/15 text-secondary">
            <.icon name="hero-clock" class="size-4" />
          </span>
          <h3 class="font-semibold">Ready for a Mock Exam?</h3>
        </div>
        <p class="text-sm text-base-content/60 mt-1">Nursing CBT Mock Examination · NMCN format</p>

        <div class="grid grid-cols-3 gap-2 mt-4">
          <div class="rounded-2xl bg-base-100/70 p-3 text-center">
            <p class="text-lg font-bold">{@format.question_count}</p>
            <p class="text-[11px] uppercase tracking-wide text-base-content/50">Questions</p>
          </div>
          <div class="rounded-2xl bg-base-100/70 p-3 text-center">
            <p class="text-lg font-bold">{div(@format.time_limit_seconds, 60)}</p>
            <p class="text-[11px] uppercase tracking-wide text-base-content/50">Minutes</p>
          </div>
          <div class="rounded-2xl bg-base-100/70 p-3 text-center">
            <p class="text-lg font-bold">{readiness_label(@readiness_score)}</p>
            <p class="text-[11px] uppercase tracking-wide text-base-content/50">Readiness</p>
          </div>
        </div>

        <p :if={@latest_exam} class="text-sm text-base-content/70 mt-4">
          Last attempt:
          <span class="font-semibold">{Formatting.percent(exam_percent(@latest_exam))}</span>
          ({@latest_exam.score}/{@latest_exam.question_count})
        </p>
        <p :if={!@latest_exam} class="text-sm text-base-content/60 mt-4">
          No mock exams completed yet.
        </p>

        <div class="flex flex-col sm:flex-row sm:flex-wrap gap-3 mt-5">
          <.link
            :if={@can_start}
            navigate={~p"/exam/new"}
            class="btn btn-secondary rounded-full flex-1 sm:flex-none"
          >
            Start Mock Exam
          </.link>
          <.link
            :if={!@can_start}
            navigate={~p"/subscription"}
            class="btn btn-secondary rounded-full flex-1 sm:flex-none"
          >
            Upgrade to Unlock
          </.link>
          <.link navigate={~p"/analytics"} class="btn btn-ghost rounded-full flex-1 sm:flex-none">
            View Full Analysis
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp readiness_label(nil), do: "Unrated"
  defp readiness_label(score) when score >= 80, do: "Excellent"
  defp readiness_label(score) when score >= 60, do: "Good"
  defp readiness_label(score) when score >= 40, do: "Fair"
  defp readiness_label(_score), do: "Needs Work"

  defp exam_percent(%{score: score, question_count: count}) when count > 0,
    do: Float.round(score / count * 100, 1)

  defp exam_percent(_exam), do: nil

  ## Streak widget

  @doc "Current/longest streak plus a Mon-Sun weekly activity grid."
  attr :current, :integer, required: true
  attr :longest, :integer, required: true
  attr :week, :map, required: true

  def streak_widget(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-base-100 border border-base-300">
      <div class="card-body p-5 sm:p-6">
        <h3 class="font-semibold">Your Study Streak</h3>
        <p class="text-3xl font-extrabold mt-2 flex items-center gap-2">
          <span aria-hidden="true">🔥</span>
          {@current}
          <span class="text-base font-medium text-base-content/50">day{if @current != 1, do: "s"}</span>
        </p>

        <div class="grid grid-cols-7 gap-1.5 mt-4">
          <div :for={d <- @week.days} class="flex flex-col items-center gap-1">
            <span class="text-[10px] font-medium text-base-content/40 uppercase">{d.label}</span>
            <span class={[
              "flex size-7 sm:size-8 items-center justify-center rounded-full text-xs",
              d.answered && "bg-success text-success-content",
              !d.answered && d.is_today && "border-2 border-primary text-primary",
              !d.answered && !d.is_today && !d.is_future && "bg-base-200 text-base-content/30",
              !d.answered && d.is_future &&
                "border border-dashed border-base-300 text-base-content/20"
            ]}>
              <.icon :if={d.answered} name="hero-check-circle" class="size-4" />
              <span :if={!d.answered} aria-hidden="true">·</span>
            </span>
          </div>
        </div>

        <div class="flex items-center justify-between text-sm text-base-content/60 mt-4">
          <span>Longest streak: <span class="font-semibold text-base-content">{@longest} days</span></span>
          <span>Goal: <span class="font-semibold text-base-content">{@week.goal}/week</span></span>
        </div>

        <progress class="progress progress-primary w-full mt-2" value={@week.met} max={@week.goal} />

        <.link navigate={~p"/practice"} class="btn btn-primary btn-soft rounded-full w-full mt-4">
          Continue Your Streak
        </.link>
      </div>
    </div>
    """
  end

  ## Leaderboard widget

  @doc "Compact top-5 weekly leaderboard, current user highlighted if present."
  attr :board, :list, required: true
  attr :current_user_id, :integer, required: true

  def leaderboard_widget(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-base-100 border border-base-300">
      <div class="card-body p-5 sm:p-6">
        <div class="flex items-center justify-between">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-trophy" class="size-4 text-warning" /> Weekly Leaderboard
          </h3>
          <.link navigate={~p"/leaderboard"} class="text-sm link">View all</.link>
        </div>

        <.empty_state :if={@board == []} icon="hero-trophy" class="py-8">
          No ranked activity yet this week.
        </.empty_state>

        <ol :if={@board != []} class="mt-3 space-y-1.5">
          <li
            :for={{row, i} <- Enum.with_index(@board, 1)}
            class={[
              "flex items-center justify-between p-2.5 rounded-xl border",
              (row.user_id == @current_user_id && "bg-primary/10 border-primary/30") ||
                "border-transparent"
            ]}
          >
            <span class="flex items-center gap-2.5 min-w-0">
              <span class="w-6 text-center text-sm font-bold text-base-content/60">{medal(i)}</span>
              <span class="font-medium truncate">{row.name || "Student"}</span>
            </span>
            <span class="text-sm text-base-content/60 shrink-0">{row.correct} correct</span>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(n), do: "#{n}"

  ## AI study assistant teaser

  @doc "Static teaser linking into the real AI tutor-never calls `AiTutor` itself (that's a billed API call, must never fire from a dashboard page load)."
  attr :weak_areas, :list, required: true

  def ai_assistant_teaser(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-gradient-to-br from-accent/15 via-accent/5 to-transparent border border-accent/25">
      <div class="card-body p-5 sm:p-6">
        <div class="flex items-center gap-2">
          <span class="flex size-9 items-center justify-center rounded-full bg-accent/20 text-accent-content">
            <.icon name="hero-sparkles" class="size-4" />
          </span>
          <h3 class="font-semibold">Your Personal Study Assistant</h3>
        </div>
        <p class="text-sm text-base-content/70 mt-2">
          <%= if @weak_areas != [] do %>
            You're weakest in <span class="font-semibold">{hd(@weak_areas).topic_name}</span>
            at {Formatting.percent(hd(@weak_areas).accuracy)}. Ask the tutor to walk through it with you.
          <% else %>
            Answer a few practice questions and I'll point you to what's worth reviewing next.
          <% end %>
        </p>
        <div class="flex gap-3 mt-4">
          <.link navigate={~p"/tutor?explain=weak_areas"} class="btn btn-accent btn-sm rounded-full">
            Ask Study Assistant
          </.link>
          <.link navigate={~p"/tutor"} class="btn btn-ghost btn-sm rounded-full">Open Tutor</.link>
        </div>
      </div>
    </div>
    """
  end

  ## Quick actions

  @doc "Static shortcut grid into the real practice/exam/analytics/tutor/leaderboard routes."
  attr :review_path, :string, required: true

  def quick_actions(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-base-100 border border-base-300">
      <div class="card-body p-5 sm:p-6">
        <h3 class="font-semibold mb-3">Quick Actions</h3>
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-2.5">
          <.quick_action_link navigate={~p"/practice"} icon="hero-pencil-square" label="Practice" />
          <.quick_action_link navigate={~p"/exam/new"} icon="hero-clock" label="Mock Exam" />
          <.quick_action_link navigate={~p"/practice"} icon="hero-bolt" label="Daily Challenge" />
          <.quick_action_link
            navigate={@review_path}
            icon="hero-arrow-trending-down"
            label="Review Mistakes"
          />
          <.quick_action_link navigate={~p"/tutor"} icon="hero-sparkles" label="Study Resources" />
          <.quick_action_link navigate={~p"/leaderboard"} icon="hero-trophy" label="Leaderboard" />
        </div>
      </div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp quick_action_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex flex-col items-center gap-1.5 p-3 rounded-2xl border border-base-300 hover:border-primary hover:bg-primary/5 transition-colors text-center"
    >
      <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary">
        <.icon name={@icon} class="size-4" />
      </span>
      <span class="text-xs font-medium">{@label}</span>
    </.link>
    """
  end

  ## Profile summary

  @doc "Compact profile card: initials avatar (no photo field exists), real readiness/streak figures, exam-date countdown if set."
  attr :profile, :any, default: nil
  attr :readiness_score, :integer, default: nil
  attr :streak, :integer, required: true

  def profile_summary(assigns) do
    ~H"""
    <div class="card rounded-3xl bg-base-100 border border-base-300">
      <div class="card-body p-5 sm:p-6 items-center text-center">
        <div class="flex size-16 items-center justify-center rounded-full bg-primary/10 text-primary text-xl font-bold">
          {initials(@profile)}
        </div>
        <p class="font-semibold mt-3">
          {(@profile && @profile.full_name) || "Complete your profile"}
        </p>
        <p class="text-xs text-base-content/50">Nursing Exam Candidate</p>

        <div class="w-full grid grid-cols-2 gap-2 mt-4 text-sm">
          <div class="rounded-2xl bg-base-200 py-2.5">
            <p class="font-bold">{Formatting.percent(@readiness_score)}</p>
            <p class="text-[11px] text-base-content/50 uppercase tracking-wide">Exam Ready</p>
          </div>
          <div class="rounded-2xl bg-base-200 py-2.5">
            <p class="font-bold">{@streak}</p>
            <p class="text-[11px] text-base-content/50 uppercase tracking-wide">Day Streak</p>
          </div>
        </div>

        <p :if={@profile && @profile.target_exam_date} class="text-xs text-base-content/60 mt-3">
          {exam_countdown(@profile.target_exam_date)}
        </p>

        <.link navigate={~p"/users/settings"} class="btn btn-ghost btn-sm rounded-full w-full mt-4">
          Edit Profile
        </.link>
      </div>
    </div>
    """
  end

  defp initials(nil), do: "?"
  defp initials(%{full_name: nil}), do: "?"

  defp initials(%{full_name: name}) do
    name
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp exam_countdown(date) do
    case Date.diff(date, Date.utc_today()) do
      n when n > 1 -> "#{n} days until your target exam date"
      1 -> "1 day until your target exam date"
      0 -> "Your target exam date is today"
      _n -> "Your target exam date has passed-update it in settings"
    end
  end

  ## Insights ("notifications")

  @doc "Live-computed, ephemeral insight strings-never persisted. Also what the shell's notification-bell dropdown renders."
  attr :insights, :list, required: true

  def insight_banner(assigns) do
    ~H"""
    <.empty_state :if={@insights == []} icon="hero-check-circle">
      You're all caught up-nothing new to flag right now.
    </.empty_state>
    <div :if={@insights != []} class="space-y-2">
      <.link
        :for={i <- @insights}
        navigate={i.cta_path}
        class={[
          "flex items-center gap-3 p-3.5 rounded-2xl border transition-colors hover:bg-base-200",
          insight_border(i.tone)
        ]}
      >
        <span class={[
          "flex size-8 shrink-0 items-center justify-center rounded-full bg-current/10",
          insight_color(i.tone)
        ]}>
          <.icon name={i.icon} class="size-4" />
        </span>
        <span class="flex-1 text-sm text-left">{i.text}</span>
        <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0" />
      </.link>
    </div>
    """
  end

  defp insight_color(:success), do: "text-success"
  defp insight_color(:warning), do: "text-warning"
  defp insight_color(_tone), do: "text-primary"
  defp insight_border(:success), do: "border-success/20 bg-success/5"
  defp insight_border(:warning), do: "border-warning/20 bg-warning/5"
  defp insight_border(_tone), do: "border-primary/20 bg-primary/5"

  ## Loading skeleton

  @doc """
  Generic card-shaped loading skeleton. Not wired to any real loading state
  today-every dashboard query is one fast synchronous DB hit in `mount/3`,
  so there's nothing to show a skeleton for yet. Kept as a documented,
  ready-to-use component should a section ever graduate to `assign_async`.
  """
  attr :class, :any, default: nil
  attr :lines, :integer, default: 3

  def card_skeleton(assigns) do
    ~H"""
    <div
      class={["card rounded-3xl bg-base-100 border border-base-300 animate-pulse", @class]}
      aria-hidden="true"
    >
      <div class="card-body p-5 sm:p-6 space-y-3">
        <div class="h-4 w-1/3 rounded bg-base-300"></div>
        <div :for={_line <- 1..@lines} class="h-3 w-full rounded bg-base-200"></div>
      </div>
    </div>
    """
  end
end
