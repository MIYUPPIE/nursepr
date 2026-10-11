defmodule NursePrep.Repo.Migrations.CreateQuizzesDomain do
  use Ecto.Migration

  def change do
    create table(:quiz_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :mode, :string, null: false
      add :channel, :string, null: false, default: "web"
      add :exam_track, :string
      add :subject_id, references(:subjects, on_delete: :nilify_all)
      add :topic_id, references(:topics, on_delete: :nilify_all)
      add :status, :string, null: false, default: "in_progress"
      add :question_count, :integer, null: false
      add :time_limit_seconds, :integer
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :score, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:quiz_sessions, [:user_id, :status])
    create index(:quiz_sessions, [:user_id, :mode, :inserted_at])

    create table(:quiz_answers) do
      add :quiz_session_id, references(:quiz_sessions, on_delete: :delete_all), null: false
      add :question_id, references(:questions, on_delete: :restrict), null: false
      add :selected_option_id, references(:options, on_delete: :nilify_all)
      add :is_correct, :boolean
      add :channel, :string, null: false, default: "web"
      add :answered_at, :utc_datetime
      add :time_spent_ms, :integer
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:quiz_answers, [:quiz_session_id, :question_id])
    create index(:quiz_answers, [:question_id])
  end
end
