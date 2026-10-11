defmodule NursePrep.Quizzes do
  @moduledoc """
  Practice sessions and timed mock exams. A `quiz_session` owns an ordered
  set of `quiz_answers` rows created up front (one per question, in a fixed
  order)-answering just fills in `selected_option_id`/`is_correct` on the
  matching row, so the session's question order never depends on
  re-querying `random_question_set/1` again after the fact.
  """

  import Ecto.Query, warn: false

  alias NursePrep.Repo
  alias NursePrep.Questions
  alias NursePrep.Questions.Option
  alias NursePrep.Quizzes.{QuizSession, QuizAnswer}

  @practice_question_count Application.compile_env(:nurseprep, :practice_question_count, 10)

  @doc "Starts an untimed practice session, optionally filtered by subject/topic."
  def start_practice_session(user, filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :question_count, @practice_question_count)
    channel = Keyword.get(opts, :channel, "web")

    questions =
      Questions.random_question_set(
        limit: limit,
        subject_id: filters[:subject_id],
        topic_id: filters[:topic_id]
      )

    create_session(
      user,
      %{
        "mode" => "practice",
        "channel" => channel,
        "subject_id" => filters[:subject_id],
        "topic_id" => filters[:topic_id]
      },
      questions
    )
  end

  @doc "Starts a timed mock exam using the configured question count/time limit."
  def start_exam_session(user, opts \\ []) do
    channel = Keyword.get(opts, :channel, "web")
    format = exam_format()

    questions = Questions.random_question_set(limit: format[:question_count])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    create_session(
      user,
      %{
        "mode" => "exam",
        "channel" => channel,
        "time_limit_seconds" => format[:time_limit_minutes] * 60,
        "expires_at" => DateTime.add(now, format[:time_limit_minutes] * 60, :second)
      },
      questions
    )
  end

  @doc "The NMCN mock exam format-one board exam, so one format for everyone."
  def exam_format do
    Application.get_env(:nurseprep, :exam_format, question_count: 100, time_limit_minutes: 90)
  end

  defp create_session(user, attrs, questions) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base_attrs =
      Map.merge(attrs, %{
        "user_id" => user.id,
        "question_count" => length(questions),
        "started_at" => now
      })

    Repo.transaction(fn ->
      with {:ok, session} <- %QuizSession{} |> QuizSession.changeset(base_attrs) |> Repo.insert() do
        questions
        |> Enum.with_index(1)
        |> Enum.each(fn {question, position} ->
          %QuizAnswer{}
          |> QuizAnswer.changeset(%{
            "quiz_session_id" => session.id,
            "question_id" => question.id,
            "position" => position,
            "channel" => attrs["channel"] || "web"
          })
          |> Repo.insert!()
        end)

        get_session!(session.id)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def get_session!(id) do
    QuizSession
    |> preload(quiz_answers: [question: [:options, :explanation, :subject]])
    |> Repo.get!(id)
  end

  @doc "Recently completed sessions for a user, newest first-used by the student dashboard."
  def list_recent_sessions(user, limit \\ 5) do
    QuizSession
    |> where([s], s.user_id == ^user.id and s.status in ["completed", "expired"])
    |> order_by(desc: :completed_at)
    |> limit(^limit)
    |> preload([:subject, :topic])
    |> Repo.all()
  end

  @doc """
  Lightweight completed-session stats for the student dashboard (total
  answered, overall accuracy). The fuller readiness-score/weak-areas
  breakdown lives in `NursePrep.Analytics`.
  """
  def student_stats(user) do
    answered_query =
      from a in QuizAnswer,
        join: s in QuizSession,
        on: a.quiz_session_id == s.id,
        where: s.user_id == ^user.id and not is_nil(a.answered_at)

    total_answered = Repo.aggregate(answered_query, :count)
    correct = Repo.aggregate(from(a in answered_query, where: a.is_correct == true), :count)

    completed_sessions =
      Repo.aggregate(
        from(s in QuizSession,
          where: s.user_id == ^user.id and s.status in ["completed", "expired"]
        ),
        :count
      )

    %{
      total_answered: total_answered,
      accuracy:
        if(total_answered > 0, do: Float.round(correct / total_answered * 100, 1), else: nil),
      completed_sessions: completed_sessions
    }
  end

  @doc "How many practice questions `user` has answered today across every channel-the free-tier paywall's counter."
  def practice_questions_answered_today(user) do
    today_start =
      DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.aggregate(
      from(a in QuizAnswer,
        join: s in QuizSession,
        on: a.quiz_session_id == s.id,
        where: s.user_id == ^user.id and s.mode == "practice" and a.answered_at >= ^today_start
      ),
      :count
    )
  end

  @doc "Most recently completed/expired mock exam-the dashboard's mock-exam promo card and `Analytics.period_comparison/1`'s 'latest attempt' figure."
  def latest_exam_session(user) do
    QuizSession
    |> where(
      [s],
      s.user_id == ^user.id and s.mode == "exam" and s.status in ["completed", "expired"]
    )
    # `completed_at` is second-truncated, so two exams submitted in the same
    # wall-clock second tie on it-`:id` breaks the tie deterministically.
    |> order_by(desc: :completed_at, desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Whether `user` has completed a mixed (no subject/topic filter) practice
  session today-the "Daily Challenge" card's completion checkmark. Not a
  distinct session type: the default practice question count
  (`@practice_question_count`) already matches the brief's 10-question
  daily challenge, so this is just a label over the existing practice
  flow, not new state.
  """
  def daily_challenge_completed_today?(user) do
    today_start =
      DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.exists?(
      from(s in QuizSession,
        where:
          s.user_id == ^user.id and s.mode == "practice" and is_nil(s.subject_id) and
            is_nil(s.topic_id) and s.status in ["completed", "expired"] and
            s.completed_at >= ^today_start
      )
    )
  end

  @doc "Finds an in-progress session for the user, if any (used to resume after a disconnect)."
  def resume_session(user, mode) do
    QuizSession
    |> where([s], s.user_id == ^user.id and s.mode == ^mode and s.status == "in_progress")
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      session -> get_session!(session.id)
    end
  end

  @doc "Records the user's answer for one question in the session."
  def answer_question(%QuizSession{} = session, question_id, selected_option_id, opts \\ []) do
    answer = Enum.find(session.quiz_answers, &(&1.question_id == question_id))
    option = selected_option_id && Repo.get(Option, selected_option_id)

    answer
    |> QuizAnswer.changeset(%{
      "selected_option_id" => selected_option_id,
      "is_correct" => option && option.is_correct,
      "answered_at" => DateTime.utc_now() |> DateTime.truncate(:second),
      "time_spent_ms" => opts[:time_spent_ms]
    })
    |> Repo.update()
  end

  @doc "Finalizes a session: computes the score and marks it completed (or expired, for a timed-out exam)."
  def submit_session(%QuizSession{} = session, status \\ "completed") do
    score =
      Repo.aggregate(
        from(a in QuizAnswer, where: a.quiz_session_id == ^session.id and a.is_correct == true),
        :count
      )

    result =
      session
      |> QuizSession.changeset(%{
        "status" => status,
        "score" => score,
        "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()

    with {:ok, _} <- result do
      Phoenix.PubSub.broadcast(NursePrep.PubSub, "leaderboard", :leaderboard_updated)
    end

    result
  end

  @doc "Per-question review data for the results page: the user's answer, the correct one, and its explanation."
  def session_summary(%QuizSession{} = session) do
    session = get_session!(session.id)

    %{
      session: session,
      answered_count: Enum.count(session.quiz_answers, & &1.answered_at),
      correct_count: Enum.count(session.quiz_answers, & &1.is_correct),
      answers: session.quiz_answers
    }
  end

  @doc """
  Auto-submits any exam session whose time limit has passed but is still
  in_progress (Oban cron). Returns the expired sessions with `:user`
  preloaded so the caller can notify students who have no client-side
  timer to redirect them automatically-see
  `Whatsapp.Workers.AutoSubmitExpiredExamWorker`-a whatsapp-channel exam
  otherwise "expires" with no student ever finding out.
  """
  def expire_overdue_exams do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    QuizSession
    |> where([s], s.mode == "exam" and s.status == "in_progress" and s.expires_at < ^now)
    |> preload(:user)
    |> Repo.all()
    |> Enum.map(fn session ->
      {:ok, submitted} = submit_session(session, "expired")
      %{submitted | user: session.user}
    end)
  end
end
