defmodule NursePrep.AnalyticsTest do
  use NursePrep.DataCase, async: true

  import NursePrep.Factory
  import NursePrep.AccountsFixtures
  import NursePrep.QuizFixtures

  alias NursePrep.Analytics

  describe "readiness_score/1" do
    test "returns nil for a user who hasn't answered anything" do
      assert Analytics.readiness_score(user_fixture()) == nil
    end

    test "returns a score between 0 and 100 once questions are answered" do
      user = user_fixture()
      answer_n_questions(user, 20, correct_fraction: 0.8)

      score = Analytics.readiness_score(user)
      assert score
      assert score >= 0 and score <= 100
    end

    test "higher recent accuracy yields a higher score than lower accuracy, all else equal" do
      strong_user = user_fixture()
      weak_user = user_fixture()

      answer_n_questions(strong_user, 30, correct_fraction: 0.9)
      answer_n_questions(weak_user, 30, correct_fraction: 0.2)

      assert Analytics.readiness_score(strong_user) > Analytics.readiness_score(weak_user)
    end
  end

  describe "weak_areas/2" do
    test "excludes topics below the minimum attempt threshold (avoids noise)" do
      user = user_fixture()
      topic = insert(:topic)
      # Only 2 attempts, both wrong-should NOT show up as a "weak area" yet.
      answer_topic_questions(user, topic, 2, correct_fraction: 0.0)

      assert Analytics.weak_areas(user) == []
    end

    test "surfaces topics under the accuracy threshold with enough attempts, weakest first" do
      user = user_fixture()
      weak_topic = insert(:topic, name: "Pharmacology Weak")
      strong_topic = insert(:topic, name: "Anatomy Strong")

      answer_topic_questions(user, weak_topic, 10, correct_fraction: 0.2)
      answer_topic_questions(user, strong_topic, 10, correct_fraction: 0.9)

      [weakest | _] = Analytics.weak_areas(user)
      assert weakest.topic_name == "Pharmacology Weak"
      assert weakest.accuracy < 70.0
      refute Enum.any?(Analytics.weak_areas(user), &(&1.topic_name == "Anatomy Strong"))
    end
  end

  describe "topic_accuracy/1" do
    test "reports accuracy and attempt count per topic" do
      user = user_fixture()
      topic = insert(:topic, name: "Community Health")
      answer_topic_questions(user, topic, 5, correct_fraction: 0.6)

      [row] = Analytics.topic_accuracy(user)
      assert row.topic_name == "Community Health"
      assert row.attempts == 5
      assert row.accuracy == 60.0
    end
  end

  describe "streak/1" do
    test "is 0 for a user with no answers" do
      assert Analytics.streak(user_fixture()) == 0
    end

    test "counts consecutive days ending today" do
      user = user_fixture()
      answer_on_date(user, Date.utc_today())
      answer_on_date(user, Date.add(Date.utc_today(), -1))
      answer_on_date(user, Date.add(Date.utc_today(), -2))
      # A gap two days back breaks the streak at 3.
      answer_on_date(user, Date.add(Date.utc_today(), -4))

      assert Analytics.streak(user) == 3
    end

    test "is 0 if the user's most recent activity wasn't today" do
      user = user_fixture()
      answer_on_date(user, Date.add(Date.utc_today(), -1))

      assert Analytics.streak(user) == 0
    end
  end

  describe "leaderboard/2" do
    test "ranks users by correct answers, respecting leaderboard_opt_in" do
      top_user = user_fixture()
      insert(:profile_for, user: top_user, full_name: "Top Scorer", leaderboard_opt_in: true)
      answer_n_questions(top_user, 10, correct_fraction: 1.0)

      opted_out_user = user_fixture()
      insert(:profile_for, user: opted_out_user, full_name: "Hidden", leaderboard_opt_in: false)
      answer_n_questions(opted_out_user, 10, correct_fraction: 1.0)

      board = Analytics.leaderboard(:all_time)
      assert Enum.any?(board, &(&1.name == "Top Scorer"))
      refute Enum.any?(board, &(&1.name == "Hidden"))
    end

    test "weekly scope excludes answers older than 7 days" do
      user = user_fixture()
      insert(:profile_for, user: user, full_name: "Old Timer", leaderboard_opt_in: true)
      answer_on_date(user, Date.add(Date.utc_today(), -10))

      board = Analytics.leaderboard(:weekly)
      refute Enum.any?(board, &(&1.name == "Old Timer"))
    end
  end

  describe "subject_accuracy/1" do
    test "reports accuracy and attempt count per subject" do
      user = user_fixture()
      topic = insert(:topic, name: "Community Health")
      answer_topic_questions(user, topic, 5, correct_fraction: 0.6)

      [row] = Analytics.subject_accuracy(user)
      assert row.subject_id == topic.subject_id
      assert row.subject_name == topic.subject.name
      assert row.attempts == 5
      assert row.accuracy == 60.0
    end

    test "is empty for a user with no answers" do
      assert Analytics.subject_accuracy(user_fixture()) == []
    end
  end

  describe "longest_streak/1" do
    test "is 0 for a user with no answers" do
      assert Analytics.longest_streak(user_fixture()) == 0
    end

    test "finds the longest historical run, even if it isn't the current one" do
      user = user_fixture()
      today = Date.utc_today()

      # A 4-day run 10 days ago, then a gap, then a 2-day run ending today.
      answer_on_date(user, Date.add(today, -10))
      answer_on_date(user, Date.add(today, -11))
      answer_on_date(user, Date.add(today, -12))
      answer_on_date(user, Date.add(today, -13))
      answer_on_date(user, Date.add(today, -1))
      answer_on_date(user, today)

      assert Analytics.longest_streak(user) == 4
      assert Analytics.streak(user) == 2
    end
  end

  describe "week_activity/1" do
    test "marks today's activity and future days correctly, with the fixed weekly goal" do
      user = user_fixture()
      answer_on_date(user, Date.utc_today())

      result = Analytics.week_activity(user)

      assert result.goal == 5
      assert result.met == 1
      assert length(result.days) == 7
      today_entry = Enum.find(result.days, & &1.is_today)
      assert today_entry.answered

      future_days = Enum.filter(result.days, & &1.is_future)
      assert Enum.all?(future_days, &(&1.answered == false))
    end

    test "excludes activity from before this Monday" do
      user = user_fixture()
      # 10 days back is guaranteed to fall in a prior calendar week.
      answer_on_date(user, Date.add(Date.utc_today(), -10))

      result = Analytics.week_activity(user)
      assert result.met == 0
    end
  end

  describe "daily_series/2" do
    test "zero-fills days with no activity and leaves accuracy nil (not 0) on them" do
      user = user_fixture()
      answer_on_date(user, Date.utc_today())

      series = Analytics.daily_series(user, :days_7)

      assert length(series) == 7
      today_row = List.last(series)
      assert today_row.date == Date.utc_today()
      assert today_row.answered == 1
      # `answer_on_date/2` always selects the first (incorrect) option.
      assert today_row.accuracy == 0.0

      empty_row = hd(series)
      assert empty_row.answered == 0
      assert empty_row.accuracy == nil
    end

    test ":all starts from the user's first answer, not a hardcoded epoch" do
      user = user_fixture()
      answer_on_date(user, Date.add(Date.utc_today(), -3))

      series = Analytics.daily_series(user, :all)
      assert length(series) == 4
    end

    test ":all is a single day for a brand-new user with no answers" do
      series = Analytics.daily_series(user_fixture(), :all)
      assert length(series) == 1
    end
  end

  describe "period_comparison/1" do
    test "computes rolling week-over-week deltas" do
      user = user_fixture()
      answer_n_questions(user, 10, correct_fraction: 0.5)

      result = Analytics.period_comparison(user)

      assert result.answered_this_week == 10
      assert result.answered_delta == 10
      assert result.accuracy_this_week == 50.0
      # No answers in the prior week, so there's nothing to diff against.
      assert result.accuracy_delta == nil
      assert result.current_streak == 1
    end

    test "accuracy_delta is nil, not a false 0, when either period has no data" do
      user = user_fixture()
      assert Analytics.period_comparison(user).accuracy_delta == nil
    end

    test "surfaces the latest completed mock exam" do
      user = user_fixture()
      for _ <- 1..3, do: insert_question_with_options()
      {:ok, session} = NursePrep.Quizzes.start_exam_session(user)
      {:ok, _} = NursePrep.Quizzes.submit_session(session)

      result = Analytics.period_comparison(user)
      assert result.latest_exam.question_count == session.question_count
      assert result.latest_exam.completed_at
    end

    test "latest_exam is nil when the user hasn't sat one" do
      assert Analytics.period_comparison(user_fixture()).latest_exam == nil
    end
  end
end
