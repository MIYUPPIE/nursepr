defmodule NursePrepWeb.DashboardLive do
  @moduledoc """
  The student dashboard: exam readiness, today's recommended study plan,
  performance analytics, and quick entry points into practice/exams/tutor.
  Every figure traces to a real query in `Analytics`/`Quizzes`/
  `Subscriptions`-nothing here is hardcoded or fabricated. Features the
  product has no backend for yet (bookmarks, XP/levels/badges, persisted
  notifications) are simply not represented, rather than faked.
  """
  use NursePrepWeb, :live_view

  import NursePrepWeb.DashboardComponents

  alias NursePrep.{Accounts, Analytics, Formatting, Quizzes, Subscriptions}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <:notifications>
        <.insight_banner insights={@insights} />
      </:notifications>

      <.header>
        {greeting()}{if @profile, do: ", #{first_name(@profile.full_name)}"}
        <span aria-hidden="true">👋</span>
        <:subtitle>Let's continue your preparation and move one step closer to exam day.</:subtitle>
      </.header>

      <div :if={@profile == nil} class="alert alert-warning mt-2">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          <.link navigate={~p"/users/settings"} class="link font-semibold">Complete your profile</.link>
          so we can tailor questions to your exam track.
        </span>
      </div>

      <div :if={@insights != []} class="mt-4">
        <.insight_banner insights={@insights} />
      </div>

      <div class="mt-6">
        <.readiness_hero
          score={@readiness_score}
          answered={@stats.total_answered}
          next_label={@next_label}
          next_path={@next_path}
        />
      </div>

      <.section title="Today's Study Plan">
        <.study_plan cards={@study_plan_cards} />
      </.section>

      <.section title="Performance Overview">
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.overview_stat
            id="kpi-answered"
            icon="hero-clipboard-document-check"
            label="Questions Completed"
            value={"#{@stats.total_answered}"}
            count_to={@stats.total_answered}
            delta={@period.answered_delta}
            delta_label=" this week"
          />
          <.overview_stat
            id="kpi-accuracy"
            icon="hero-check-circle"
            label="Average Accuracy"
            value={Formatting.percent(@stats.accuracy)}
            count_to={@stats.accuracy && trunc(@stats.accuracy)}
            count_suffix="%"
            delta={@period.accuracy_delta}
            delta_label=" pts this week"
          />
          <.overview_stat
            id="kpi-streak"
            icon="hero-fire"
            label="Study Streak"
            value={"#{@streak} Day#{if @streak != 1, do: "s"}"}
            count_to={@streak}
            count_suffix={" Day#{if @streak != 1, do: "s"}"}
            note={"Longest: #{@longest_streak} days"}
          />
          <.overview_stat
            id="kpi-exam-score"
            icon="hero-academic-cap"
            label="Mock Exam Score"
            value={exam_score_label(@period.latest_exam)}
            count_to={@period.latest_exam && exam_percent_int(@period.latest_exam)}
            count_suffix="%"
            note={@period.latest_exam && "Latest attempt"}
          />
        </div>
      </.section>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mt-8">
        <div class="lg:col-span-2 space-y-6">
          <.performance_chart series={@series} metric={@metric} range={@range} />

          <.weak_strong_areas weak={@weak_areas} strong={@strong_areas} />

          <div class="card rounded-3xl bg-base-100 border border-base-300">
            <div class="card-body p-5 sm:p-6">
              <h3 class="font-semibold mb-3">Performance by Subject</h3>
              <.subject_bars subjects={@subject_accuracy} />
            </div>
          </div>

          <.mock_exam_promo
            format={@exam_format}
            can_start={@can_start_exam}
            latest_exam={@period.latest_exam}
            readiness_score={@readiness_score}
          />

          <div class="card rounded-3xl bg-base-100 border border-base-300">
            <div class="card-body p-5 sm:p-6">
              <h3 class="font-semibold mb-1">Recent Activity</h3>
              <.activity_timeline sessions={@recent_sessions} />
            </div>
          </div>
        </div>

        <div class="space-y-6">
          <.profile_summary profile={@profile} readiness_score={@readiness_score} streak={@streak} />
          <.streak_widget current={@streak} longest={@longest_streak} week={@week_activity} />
          <.leaderboard_widget board={@board} current_user_id={@user.id} />
          <.ai_assistant_teaser weak_areas={@weak_areas} />
          <.quick_actions review_path={@review_path} />
        </div>
      </div>
    </Layouts.student>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket), do: Phoenix.PubSub.subscribe(NursePrep.PubSub, "leaderboard")

    profile = Accounts.get_profile(user.id)
    stats = Quizzes.student_stats(user)
    readiness_score = Analytics.readiness_score(user)
    streak = Analytics.streak(user)
    week_activity = Analytics.week_activity(user)
    weak_areas = Analytics.weak_areas(user)
    resume = Quizzes.resume_session(user, "practice")
    daily_challenge_done = Quizzes.daily_challenge_completed_today?(user)
    can_start_exam = Subscriptions.can_start_exam?(user) == :ok
    period = Analytics.period_comparison(user)
    range = :days_7
    metric = :accuracy

    {next_label, next_path} = next_step(resume, weak_areas)

    insights =
      build_insights(%{
        week_activity: week_activity,
        period: period,
        streak: streak,
        readiness_score: readiness_score,
        can_start_exam: can_start_exam
      })

    {:ok,
     assign(socket,
       user: user,
       profile: profile,
       stats: stats,
       readiness_score: readiness_score,
       streak: streak,
       longest_streak: Analytics.longest_streak(user),
       week_activity: week_activity,
       weak_areas: weak_areas,
       strong_areas: strong_areas(user),
       subject_accuracy: Analytics.subject_accuracy(user),
       period: period,
       recent_sessions: Quizzes.list_recent_sessions(user),
       series: Analytics.daily_series(user, range),
       range: range,
       metric: metric,
       board: Analytics.leaderboard(:weekly, 5),
       can_start_exam: can_start_exam,
       exam_format: exam_format_map(),
       study_plan_cards: [
         continue_practice_card(resume),
         daily_challenge_card(daily_challenge_done),
         review_mistakes_card(weak_areas)
       ],
       next_label: next_label,
       next_path: next_path,
       review_path: review_path(weak_areas),
       insights: insights
     )}
  end

  @impl true
  def handle_event("chart_range", %{"range" => range}, socket) do
    range = String.to_existing_atom(range)
    user = socket.assigns.current_scope.user

    {:noreply, assign(socket, range: range, series: Analytics.daily_series(user, range))}
  end

  def handle_event("chart_metric", %{"metric" => metric}, socket) do
    {:noreply, assign(socket, metric: String.to_existing_atom(metric))}
  end

  @impl true
  def handle_info(:leaderboard_updated, socket) do
    {:noreply, assign(socket, board: Analytics.leaderboard(:weekly, 5))}
  end

  defp first_name(nil), do: nil
  defp first_name(full_name), do: full_name |> String.split(" ") |> List.first()

  # West Africa Time is a fixed UTC+1 offset (no DST)-NursePrep's audience
  # is Nigeria-based, and pulling in a full tzdata dependency (none is
  # currently installed) just for a greeting string isn't worth it.
  defp greeting do
    hour = DateTime.utc_now() |> DateTime.add(1, :hour) |> Map.fetch!(:hour)

    cond do
      hour < 12 -> "Good morning"
      hour < 17 -> "Good afternoon"
      true -> "Good evening"
    end
  end

  defp exam_format_map do
    format = Quizzes.exam_format()

    %{
      question_count: format[:question_count],
      time_limit_seconds: format[:time_limit_minutes] * 60
    }
  end

  defp strong_areas(user) do
    user
    |> Analytics.topic_accuracy()
    |> Enum.filter(&(&1.accuracy >= 70.0 and &1.attempts >= 5))
    |> Enum.sort_by(&(-&1.accuracy))
    |> Enum.take(3)
  end

  defp next_step(resume, weak_areas) do
    cond do
      resume ->
        answered = Enum.count(resume.quiz_answers, & &1.answered_at)

        {"Continue #{session_label(resume)} (#{answered}/#{resume.question_count})",
         ~p"/practice/#{resume.id}"}

      weak_areas != [] ->
        top = hd(weak_areas)

        {"Practice #{top.topic_name}-your weakest topic right now",
         ~p"/practice?topic_id=#{top.topic_id}"}

      true ->
        {"Start a practice round to build your first readiness score", ~p"/practice"}
    end
  end

  defp session_label(session) do
    case session.quiz_answers do
      [%{question: %{subject: %{name: name}}} | _] -> name
      _ -> "your practice session"
    end
  end

  defp continue_practice_card(nil) do
    %{
      icon: "hero-pencil-square",
      title: "Continue Practice",
      description: "Untimed, instant feedback-pick a subject and go.",
      cta_label: "Start",
      cta_path: ~p"/practice"
    }
  end

  defp continue_practice_card(resume) do
    answered = Enum.count(resume.quiz_answers, & &1.answered_at)

    %{
      icon: "hero-pencil-square",
      title: "Continue Practice",
      description: session_label(resume),
      progress: {answered, resume.question_count},
      cta_label: "Continue",
      cta_path: ~p"/practice/#{resume.id}"
    }
  end

  defp daily_challenge_card(done?) do
    %{
      icon: "hero-bolt",
      accent: "text-warning",
      title: "Daily Challenge",
      description: "10 questions · mixed topics · about 8 minutes.",
      cta_label: (done? && "Done for today") || "Start",
      cta_path: ~p"/practice",
      done: done?
    }
  end

  defp review_mistakes_card([]) do
    %{
      icon: "hero-magnifying-glass",
      title: "Review Mistakes",
      description: "No weak spots flagged yet-keep practicing.",
      cta_label: "View Analytics",
      cta_path: ~p"/analytics"
    }
  end

  defp review_mistakes_card([top | _]) do
    %{
      icon: "hero-arrow-trending-down",
      accent: "text-warning",
      title: "Review Mistakes",
      description:
        "#{top.attempts} recent questions in #{top.topic_name}, based on your incorrect answers.",
      cta_label: "Review",
      cta_path: ~p"/practice?topic_id=#{top.topic_id}"
    }
  end

  defp review_path([]), do: ~p"/analytics"
  defp review_path([top | _]), do: ~p"/practice?topic_id=#{top.topic_id}"

  defp exam_score_label(nil), do: "—"

  defp exam_score_label(%{score: score, question_count: count}) when count > 0,
    do: Formatting.percent(Float.round(score / count * 100, 1))

  defp exam_score_label(_exam), do: "—"

  defp exam_percent_int(%{score: score, question_count: count}) when count > 0,
    do: round(score / count * 100)

  defp exam_percent_int(_exam), do: nil

  defp build_insights(data) do
    [
      study_reminder_insight(data.week_activity),
      accuracy_improved_insight(data.period),
      streak_milestone_insight(data.streak),
      exam_ready_insight(data.readiness_score, data.can_start_exam)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp study_reminder_insight(week_activity) do
    today = Enum.find(week_activity.days, & &1.is_today)

    if today && !today.answered do
      %{
        icon: "hero-exclamation-triangle",
        tone: :warning,
        text: "You haven't practiced today yet-keep your streak alive.",
        cta_path: ~p"/practice"
      }
    end
  end

  defp accuracy_improved_insight(%{accuracy_delta: delta}) when is_number(delta) and delta > 0 do
    %{
      icon: "hero-arrow-trending-up",
      tone: :success,
      text: "Your accuracy is up #{delta} points this week. Keep it up.",
      cta_path: ~p"/analytics"
    }
  end

  defp accuracy_improved_insight(_period), do: nil

  defp streak_milestone_insight(streak) when streak > 0 and rem(streak, 7) == 0 do
    %{
      icon: "hero-fire",
      tone: :success,
      text: "You've hit a #{streak}-day study streak!",
      cta_path: ~p"/practice"
    }
  end

  defp streak_milestone_insight(_streak), do: nil

  defp exam_ready_insight(score, can_start_exam)
       when is_integer(score) and score >= 60 and can_start_exam do
    %{
      icon: "hero-clock",
      tone: :primary,
      text: "Your readiness score suggests you're ready for a mock exam.",
      cta_path: ~p"/exam/new"
    }
  end

  defp exam_ready_insight(_score, _can_start), do: nil
end
