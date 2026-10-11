defmodule NursePrep.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :full_name, :string, null: false
      add :exam_track, :string, null: false
      add :target_exam_date, :date
      add :school, :string
      add :whatsapp_opt_in, :boolean, null: false, default: true
      add :timezone, :string, null: false, default: "Africa/Lagos"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:profiles, [:user_id])
  end
end
