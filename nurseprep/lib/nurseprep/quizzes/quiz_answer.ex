defmodule NursePrep.Quizzes.QuizAnswer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "quiz_answers" do
    field :is_correct, :boolean
    field :channel, :string, default: "web"
    field :answered_at, :utc_datetime
    field :time_spent_ms, :integer
    field :position, :integer

    belongs_to :quiz_session, NursePrep.Quizzes.QuizSession
    belongs_to :question, NursePrep.Questions.Question
    belongs_to :selected_option, NursePrep.Questions.Option

    timestamps(type: :utc_datetime)
  end

  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [
      :quiz_session_id,
      :question_id,
      :selected_option_id,
      :is_correct,
      :channel,
      :answered_at,
      :time_spent_ms,
      :position
    ])
    |> validate_required([:quiz_session_id, :question_id, :position])
    |> foreign_key_constraint(:quiz_session_id)
    |> foreign_key_constraint(:question_id)
    |> foreign_key_constraint(:selected_option_id)
    |> unique_constraint([:quiz_session_id, :question_id])
  end
end
