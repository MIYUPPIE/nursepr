defmodule NursePrep.QuizFixtures do
  @moduledoc """
  Test helpers for driving `NursePrep.Quizzes` sessions to a completed,
  scored state-used anywhere a test needs real `quiz_answers` rows to
  exist (Analytics, Dashboard/Analytics/Leaderboard LiveViews).
  """

  import NursePrep.Factory

  alias NursePrep.Quizzes

  @doc "Answers `n` freshly-created questions for `user`, `fraction` of them correctly, then submits the session."
  def answer_n_questions(user, n, correct_fraction: fraction) do
    questions = for _ <- 1..n, do: insert_question_with_options()
    {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: n)
    answer_session(session, questions, fraction)
  end

  @doc "Same as `answer_n_questions/2` but every question is tagged to `topic`."
  def answer_topic_questions(user, topic, n, correct_fraction: fraction) do
    questions =
      for _ <- 1..n, do: insert_question_with_options(topic: topic, subject: topic.subject)

    {:ok, session} =
      Quizzes.start_practice_session(user, %{topic_id: topic.id}, question_count: n)

    answer_session(session, questions, fraction)
  end

  @doc "Answers one question for `user` and backdates it to `date`-for streak tests."
  def answer_on_date(user, date) do
    question = insert_question_with_options()
    {:ok, session} = Quizzes.start_practice_session(user, %{}, question_count: 1)
    answer = hd(session.quiz_answers)
    option = hd(question.options)
    {:ok, _} = Quizzes.answer_question(session, answer.question_id, option.id)

    at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

    NursePrep.Repo.get_by!(Quizzes.QuizAnswer, quiz_session_id: session.id)
    |> Ecto.Changeset.change(answered_at: at)
    |> NursePrep.Repo.update!()

    {:ok, _} = Quizzes.submit_session(session)
  end

  defp answer_session(session, questions, fraction) do
    n = length(questions)

    session.quiz_answers
    |> Enum.zip(questions)
    |> Enum.with_index()
    |> Enum.each(fn {{answer, question}, i} ->
      option =
        if i < round(n * fraction),
          do: Enum.find(question.options, & &1.is_correct),
          else: Enum.find(question.options, &(!&1.is_correct))

      Quizzes.answer_question(session, answer.question_id, option.id)
    end)

    {:ok, _} = Quizzes.submit_session(session)
  end
end
