defmodule NursePrep.Repo.Migrations.AddLeaderboardOptInToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :leaderboard_opt_in, :boolean, null: false, default: true
    end
  end
end
