defmodule NursePrep.Repo.Migrations.CreateWhatsappSessions do
  use Ecto.Migration

  def change do
    create table(:whatsapp_sessions) do
      add :phone, :string, null: false
      add :state, :map, null: false, default: %{}
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:whatsapp_sessions, [:phone])
  end
end
