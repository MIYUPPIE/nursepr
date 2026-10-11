defmodule NursePrep.Repo.Migrations.CreateAiTutorDomain do
  use Ecto.Migration

  def change do
    create table(:ai_conversations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel, :string, null: false, default: "web"
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime, null: false
      add :last_message_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ai_conversations, [:user_id, :status])

    create table(:ai_messages) do
      add :conversation_id, references(:ai_conversations, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :model, :string
      add :tokens_input, :integer
      add :tokens_output, :integer
      add :flagged, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ai_messages, [:conversation_id, :inserted_at])
  end
end
