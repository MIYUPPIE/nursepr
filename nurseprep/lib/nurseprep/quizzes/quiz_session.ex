defmodule NursePrep.Quizzes.QuizSession do
  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(practice exam)
  @channels ~w(web whatsapp telegram)
  @statuses ~w(in_progress completed abandoned expired)

  def modes, do: @modes
  def statuses, do: @statuses

  schema "quiz_sessions" do
    field :mode, :string
    field :channel, :string, default: "web"
    field :status, :string, default: "in_progress"
    field :question_count, :integer
    field :time_limit_seconds, :integer
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :score, :integer

    belongs_to :user, NursePrep.Accounts.User
    belongs_to :subject, NursePrep.Questions.Subject
    belongs_to :topic, NursePrep.Questions.Topic

    has_many :quiz_answers, NursePrep.Quizzes.QuizAnswer,
      on_delete: :delete_all,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :mode,
      :channel,
      :subject_id,
      :topic_id,
      :status,
      :question_count,
      :time_limit_seconds,
      :started_at,
      :completed_at,
      :expires_at,
      :score
    ])
    |> validate_required([:user_id, :mode, :channel, :status, :question_count, :started_at])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
  end
end
