defmodule NursePrep.Analytics do
  @moduledoc """
  Readiness scoring, weak-area detection, streaks, and the leaderboard.
  Everything here is computed on read against `quiz_answers`/`quiz_sessions`
  -no rollup/materialized table. That's the right call at MVP scale (a
  student has, at most, a few thousand answered questions); a rollup is a
  flagged future optimization if per-request query cost ever actually
  becomes a problem, not something to build pre-emptively now.
  """

  import Ecto.Query, warn: false

  alias NursePrep.Repo
  alias NursePrep.Accounts.Profile
  alias NursePrep.Questions.Topic
  alias NursePrep.Quizzes
  alias NursePrep.Quizzes.{QuizAnswer, QuizSession}

  @recent_window 200
  @volume_target 500
  @weak_area_min_attempts 5
  @weak_area_threshold 70.0
  @topic_coverage_min_attempts 10
  @weekly_streak_goal_days 5

  @doc """
  Readiness score, 0-100: 60% recent accuracy (last #{@recent_window}
  answers), 25% topic coverage (fraction of the exam track's topics with
  at least #{@topic_coverage_min_attempts} attempts), 15% volume (answered
  ÷ #{@volume_target}, capped at 100%). Returns `nil` for a user who
  hasn't answered anything yet-there's no meaningful score to show.
  """
  def readiness_score(user) do
    total_answered = count_answered(user)

    if total_answered == 0 do
      nil
    else
      recent_accuracy = recent_accuracy(user)
      coverage_ratio = coverage_ratio(user)
      volume_factor = min(1.0, total_answered / @volume_target)

      (100 * (0.6 * recent_accuracy + 0.25 * coverage_ratio + 0.15 * volume_factor))
      |> Float.round()
      |> trunc()
    end
  end

  defp count_answered(user) do
    Repo.aggregate(answered_query(user), :count)
  end

  defp recent_accuracy(user) do
    answers =
      answered_query(user)
      |> order_by(desc: :answered_at)
      |> limit(@recent_window)
      |> select([a], a.is_correct)
      |> Repo.all()

    if answers == [], do: 0.0, else: Enum.count(answers, & &1) / length(answers)
  end

  defp coverage_ratio(user) do
    total_topics = Repo.aggregate(Topic, :count)

    if total_topics == 0 do
      0.0
    else
      # `answered_query/1` already carries 2 bindings ([a, s]-QuizAnswer,
      # QuizSession); a `join` macro's binding list determines where the new
      # binding lands *positionally*, so it must name every existing binding
      # (even ones unused here, via `_s`) or the new one silently lands one
      # slot early and every later reference by name resolves to the wrong
      # thing without erroring-exactly the bug this fixes.
      covered =
        answered_query(user)
        |> join(:inner, [a, _s], q in assoc(a, :question))
        |> where([a, _s, q], not is_nil(q.topic_id))
        |> group_by([a, _s, q], q.topic_id)
        |> having([a, _s, q], count(a.id) >= @topic_coverage_min_attempts)
        |> select([a, _s, q], q.topic_id)
        |> Repo.all()
        |> length()

      min(1.0, covered / total_topics)
    end
  end

  @doc """
  Up to `limit` topics where the user is weakest: accuracy below
  #{@weak_area_threshold}% with at least #{@weak_area_min_attempts}
  attempts (fewer than that and it's noise, not a real weak area),
  ascending by accuracy.
  """
  def weak_areas(user, limit \\ 3) do
    answered_query(user)
    |> join(:inner, [a, _s], q in assoc(a, :question))
    |> join(:inner, [a, _s, q], t in assoc(q, :topic))
    |> group_by([a, _s, q, t], [t.id, t.name])
    |> having([a, _s, q, t], count(a.id) >= @weak_area_min_attempts)
    |> select([a, _s, q, t], %{
      topic_id: t.id,
      topic_name: t.name,
      accuracy:
        fragment(
          "ROUND(100.0 * SUM(CASE WHEN ? THEN 1 ELSE 0 END) / COUNT(*), 1)::float",
          a.is_correct
        ),
      attempts: count(a.id)
    })
    |> Repo.all()
    |> Enum.filter(&(&1.accuracy < @weak_area_threshold))
    |> Enum.sort_by(& &1.accuracy)
    |> Enum.take(limit)
  end

  @doc "Per-topic accuracy breakdown for the analytics page."
  def topic_accuracy(user) do
    answered_query(user)
    |> join(:inner, [a, _s], q in assoc(a, :question))
    |> join(:inner, [a, _s, q], t in assoc(q, :topic))
    |> group_by([a, _s, q, t], [t.id, t.name])
    |> select([a, _s, q, t], %{
      topic_name: t.name,
      accuracy:
        fragment(
          "ROUND(100.0 * SUM(CASE WHEN ? THEN 1 ELSE 0 END) / COUNT(*), 1)::float",
          a.is_correct
        ),
      attempts: count(a.id)
    })
    |> order_by([a, _s, q, t], t.name)
    |> Repo.all()
  end

  @doc "Per-subject accuracy breakdown-same shape as `topic_accuracy/1`, one level up the taxonomy (`questions.subject_id` is direct, so this doesn't need to join through topics)."
  def subject_accuracy(user) do
    answered_query(user)
    |> join(:inner, [a, _s], q in assoc(a, :question))
    |> join(:inner, [a, _s, q], sub in assoc(q, :subject))
    |> group_by([a, _s, q, sub], [sub.id, sub.name])
    |> select([a, _s, q, sub], %{
      subject_id: sub.id,
      subject_name: sub.name,
      accuracy:
        fragment(
          "ROUND(100.0 * SUM(CASE WHEN ? THEN 1 ELSE 0 END) / COUNT(*), 1)::float",
          a.is_correct
        ),
      attempts: count(a.id)
    })
    |> order_by([a, _s, q, sub], sub.name)
    |> Repo.all()
  end

  @doc "Consecutive days (through today) with at least one answered question."
  def streak(user) do
    dates =
      answered_query(user)
      |> select([a], fragment("DISTINCT ?::date", a.answered_at))
      |> Repo.all()
      |> MapSet.new()

    count_consecutive_days(dates, Date.utc_today(), 0)
  end

  defp count_consecutive_days(dates, date, count) do
    if MapSet.member?(dates, date) do
      count_consecutive_days(dates, Date.add(date, -1), count + 1)
    else
      count
    end
  end

  @doc "Longest historical run of consecutive answered-days-not just the current one (see `streak/1`, which only walks backward from today)."
  def longest_streak(user) do
    answered_query(user)
    |> select([a], fragment("DISTINCT ?::date", a.answered_at))
    |> Repo.all()
    |> Enum.sort(Date)
    |> longest_run()
  end

  defp longest_run([]), do: 0

  defp longest_run([first | rest]) do
    {longest, _current, _prev} =
      Enum.reduce(rest, {1, 1, first}, fn date, {longest, current, prev} ->
        if Date.diff(date, prev) == 1 do
          next_current = current + 1
          {max(longest, next_current), next_current, date}
        else
          {longest, 1, date}
        end
      end)

    longest
  end

  @doc """
  Which of the current week's (Monday-Sunday) days `user` has answered at
  least one question on-powers the streak widget's weekly grid. Scoped to
  *this* calendar week (unlike `streak/1`'s unbounded backward walk), so
  the query only ever touches the last few days.
  """
  def week_activity(user) do
    today = Date.utc_today()
    monday = Date.add(today, -(Date.day_of_week(today) - 1))
    monday_start = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")

    answered_dates =
      answered_query(user)
      |> where([a, _s], a.answered_at >= ^monday_start)
      |> select([a], fragment("DISTINCT ?::date", a.answered_at))
      |> Repo.all()
      |> MapSet.new()

    days =
      for offset <- 0..6 do
        date = Date.add(monday, offset)

        %{
          date: date,
          label: Calendar.strftime(date, "%a"),
          answered: MapSet.member?(answered_dates, date),
          is_today: date == today,
          is_future: Date.compare(date, today) == :gt
        }
      end

    %{days: days, goal: @weekly_streak_goal_days, met: Enum.count(days, & &1.answered)}
  end

  @doc """
  Per-day series for the performance chart: answered/correct counts,
  accuracy, and study minutes, zero-filled across the full range so the
  chart gets a continuous x-axis. `range` is `:days_7 | :days_30 |
  :days_90 | :all`.

  `accuracy` is `nil`-not `0`-on a day with no answered questions: a
  student who didn't practice that day didn't crash to 0% either, and the
  chart must render that as a gap, not a false dip. `study_minutes` is
  derived from each session's `started_at`/`completed_at` (always
  populated), not `quiz_answers.time_spent_ms` (defined in the schema but
  never set by any caller today-always nil in production).
  """
  def daily_series(user, range) do
    since = range_start(user, range)
    today = Date.utc_today()
    since_at = DateTime.new!(since, ~T[00:00:00], "Etc/UTC")

    answer_rows =
      answered_query(user)
      |> where([a, _s], a.answered_at >= ^since_at)
      |> group_by([a], fragment("?::date", a.answered_at))
      |> select([a], %{
        date: fragment("?::date", a.answered_at),
        answered: count(a.id),
        correct: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", a.is_correct))
      })
      |> Repo.all()
      |> Map.new(&{&1.date, &1})

    minutes_by_date =
      from(s in QuizSession,
        where:
          s.user_id == ^user.id and not is_nil(s.completed_at) and
            s.completed_at >= ^since_at,
        group_by: fragment("?::date", s.completed_at),
        select:
          {fragment("?::date", s.completed_at),
           fragment(
             "ROUND(SUM(EXTRACT(EPOCH FROM (? - ?))) / 60.0)::int",
             s.completed_at,
             s.started_at
           )}
      )
      |> Repo.all()
      |> Map.new()

    for date <- Date.range(since, today) do
      row = answer_rows[date]
      answered = if row, do: row.answered, else: 0
      correct = if row, do: row.correct || 0, else: 0

      %{
        date: date,
        answered: answered,
        correct: correct,
        accuracy: if(answered > 0, do: Float.round(100 * correct / answered, 1), else: nil),
        study_minutes: Map.get(minutes_by_date, date, 0)
      }
    end
  end

  defp range_start(_user, :days_7), do: Date.add(Date.utc_today(), -6)
  defp range_start(_user, :days_30), do: Date.add(Date.utc_today(), -29)
  defp range_start(_user, :days_90), do: Date.add(Date.utc_today(), -89)

  defp range_start(user, :all) do
    answered_query(user)
    |> select([a], fragment("MIN(?)::date", a.answered_at))
    |> Repo.one() || Date.utc_today()
  end

  @doc """
  This-week vs. prior-week totals for the performance-overview deltas.
  Uses a rolling 7-day window (matching `leaderboard/2`'s `:weekly`
  scope)-deliberately not `week_activity/1`'s calendar Monday-Sunday
  window, since a calendar-week delta computed on, say, a Tuesday would
  compare two days of data against a full prior week and wouldn't mean
  anything.
  """
  def period_comparison(user) do
    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7, :day)
    two_weeks_ago = DateTime.add(now, -14, :day)

    # `this_week` deliberately has no upper bound (nothing is timestamped in
    # the future), rather than `< now`-comparing a freshly-captured `now`
    # against an `:utc_datetime` column truncates both to whole seconds, so
    # a row answered in the same wall-clock second as this query would
    # otherwise be excluded by a strict `<` against its own second.
    this_week = period_totals(user, week_ago, nil)
    prior_week = period_totals(user, two_weeks_ago, week_ago)

    %{
      answered_this_week: this_week.answered,
      answered_delta: this_week.answered - prior_week.answered,
      accuracy_this_week: this_week.accuracy,
      accuracy_delta: accuracy_delta(this_week.accuracy, prior_week.accuracy),
      current_streak: streak(user),
      longest_streak: longest_streak(user),
      latest_exam: latest_exam_summary(user)
    }
  end

  defp period_totals(user, from, to) do
    query = answered_query(user) |> where([a, _s], a.answered_at >= ^from)
    query = if to, do: where(query, [a, _s], a.answered_at < ^to), else: query

    %{answered: answered, correct: correct} =
      query
      |> select([a], %{
        answered: count(a.id),
        correct: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", a.is_correct))
      })
      |> Repo.one()

    %{
      answered: answered,
      accuracy: if(answered > 0, do: Float.round(100 * (correct || 0) / answered, 1), else: nil)
    }
  end

  defp accuracy_delta(nil, _prior), do: nil
  defp accuracy_delta(_this, nil), do: nil
  defp accuracy_delta(this, prior), do: Float.round(this - prior, 1)

  defp latest_exam_summary(user) do
    case Quizzes.latest_exam_session(user) do
      nil ->
        nil

      session ->
        %{
          score: session.score,
          question_count: session.question_count,
          completed_at: session.completed_at
        }
    end
  end

  defp answered_query(user) do
    from a in QuizAnswer,
      join: s in QuizSession,
      on: a.quiz_session_id == s.id,
      where: s.user_id == ^user.id and not is_nil(a.answered_at)
  end

  @doc """
  Leaderboard by total correct answers within `scope` (`:weekly` or
  `:all_time`), limited to users who've opted in. Ties broken by total
  answered (more practice, same accuracy, ranks higher).
  """
  def leaderboard(scope \\ :weekly, limit \\ 10) do
    since =
      case scope do
        :weekly -> DateTime.utc_now() |> DateTime.add(-7, :day)
        :all_time -> ~U[1970-01-01 00:00:00Z]
      end

    from(a in QuizAnswer,
      join: s in QuizSession,
      on: a.quiz_session_id == s.id,
      join: u in assoc(s, :user),
      join: p in Profile,
      on: p.user_id == u.id,
      where:
        not is_nil(a.answered_at) and a.answered_at >= ^since and p.leaderboard_opt_in == true,
      group_by: [u.id, p.full_name],
      select: %{
        user_id: u.id,
        name: p.full_name,
        correct: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", a.is_correct)),
        answered: count(a.id)
      },
      order_by: [
        desc: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", a.is_correct)),
        desc: count(a.id)
      ],
      limit: ^limit
    )
    |> Repo.all()
  end
end
