defmodule NursePrep.QuizzesTest do
  use NursePrep.DataCase, async: true

  import NursePrep.Factory
  import NursePrep.AccountsFixtures

  alias NursePrep.Quizzes

  setup do
    %{user: user_fixture()}
  end

  describe "start_practice_session/3" do
    test "creates a session with one quiz_answer per selected question", %{user: user} do
      for _ <- 1..5, do: insert_question_with_options()

      {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 3)

      assert session.mode == "practice"
      assert session.status == "in_progress"
      assert length(session.quiz_answers) == 3
      assert Enum.all?(session.quiz_answers, &is_nil(&1.selected_option_id))
      assert Enum.map(session.quiz_answers, & &1.position) |> Enum.sort() == [1, 2, 3]
    end

    test "telegram is a valid channel", %{user: user} do
      for _ <- 1..3, do: insert_question_with_options()

      {:ok, session} =
        Quizzes.start_practice_session(user, %{}, question_count: 3, channel: "telegram")

      assert session.channel == "telegram"
    end

    test "filters by subject", %{user: user} do
      subject = insert(:subject)
      insert_question_with_options(subject: subject)
      insert_question_with_options()

      {:ok, session} =
        Quizzes.start_practice_session(user, %{subject_id: subject.id}, question_count: 5)

      assert length(session.quiz_answers) == 1
    end
  end

  describe "start_exam_session/2" do
    test "uses the configured question count and time limit", %{user: user} do
      for _ <- 1..3, do: insert_question_with_options()

      {:ok, session} = Quizzes.start_exam_session(user)

      assert session.mode == "exam"
      assert session.time_limit_seconds == 90 * 60
      assert session.expires_at
      assert DateTime.compare(session.expires_at, session.started_at) == :gt
    end
  end

  describe "answer_question/4 and submit_session/2" do
    test "scores the session based on correct answers", %{user: user} do
      q1 = insert_question_with_options()
      q2 = insert_question_with_options()

      {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 2)
      # Ensure deterministic coverage regardless of random selection order.
      session = Quizzes.get_session!(session.id)

      correct_option = fn q -> Enum.find(q.options, & &1.is_correct) end
      wrong_option = fn q -> Enum.find(q.options, &(!&1.is_correct)) end

      [a1, a2] = session.quiz_answers
      q_by_id = %{q1.id => q1, q2.id => q2}

      {:ok, _} =
        Quizzes.answer_question(
          session,
          a1.question_id,
          correct_option.(q_by_id[a1.question_id]).id
        )

      {:ok, _} =
        Quizzes.answer_question(
          session,
          a2.question_id,
          wrong_option.(q_by_id[a2.question_id]).id
        )

      session = Quizzes.get_session!(session.id)
      {:ok, submitted} = Quizzes.submit_session(session)

      assert submitted.status == "completed"
      assert submitted.score == 1
      assert submitted.completed_at
    end
  end

  describe "resume_session/2" do
    test "finds the most recent in_progress session for the mode" do
      user = user_fixture()
      insert_question_with_options()

      {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 1)

      resumed = Quizzes.resume_session(user, "practice")
      assert resumed.id == session.id
    end

    test "returns nil once the session is completed" do
      user = user_fixture()
      insert_question_with_options()

      {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 1)
      {:ok, _} = Quizzes.submit_session(session)

      assert Quizzes.resume_session(user, "practice") == nil
    end
  end

  describe "latest_exam_session/1" do
    test "is nil when the user hasn't sat a mock exam", %{user: user} do
      assert Quizzes.latest_exam_session(user) == nil
    end

    test "returns the most recently completed exam, not an in-progress one", %{user: user} do
      for _ <- 1..3, do: insert_question_with_options()
      {:ok, old} = Quizzes.start_exam_session(user)
      {:ok, old} = Quizzes.submit_session(old)

      for _ <- 1..3, do: insert_question_with_options()
      {:ok, newer} = Quizzes.start_exam_session(user)
      {:ok, newer} = Quizzes.submit_session(newer)

      for _ <- 1..3, do: insert_question_with_options()
      {:ok, _in_progress} = Quizzes.start_exam_session(user)

      latest = Quizzes.latest_exam_session(user)
      assert latest.id == newer.id
      refute latest.id == old.id
    end
  end

  describe "daily_challenge_completed_today?/1" do
    test "is false before any mixed practice session is completed", %{user: user} do
      refute Quizzes.daily_challenge_completed_today?(user)
    end

    test "is false while a mixed session is still in progress", %{user: user} do
      insert_question_with_options()
      {:ok, _session} = Quizzes.start_practice_session(user, %{}, question_count: 1)

      refute Quizzes.daily_challenge_completed_today?(user)
    end

    test "is true once a mixed (no subject/topic filter) session is completed today", %{
      user: user
    } do
      insert_question_with_options()
      {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 1)
      {:ok, _} = Quizzes.submit_session(session)

      assert Quizzes.daily_challenge_completed_today?(user)
    end

    test "is false when the only completed session today was filtered by topic", %{user: user} do
      topic = insert(:topic)
      insert_question_with_options(topic: topic, subject: topic.subject)

      {:ok, session} =
        Quizzes.start_practice_session(user, %{topic_id: topic.id}, question_count: 1)

      {:ok, _} = Quizzes.submit_session(session)

      refute Quizzes.daily_challenge_completed_today?(user)
    end
  end

  describe "expire_overdue_exams/0" do
    test "marks past-deadline in_progress exams as expired", %{user: user} do
      insert_question_with_options()
      {:ok, session} = Quizzes.start_exam_session(user)

      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      session |> Ecto.Changeset.change(expires_at: past) |> NursePrep.Repo.update!()

      Quizzes.expire_overdue_exams()

      assert Quizzes.get_session!(session.id).status == "expired"
    end
  end
end
