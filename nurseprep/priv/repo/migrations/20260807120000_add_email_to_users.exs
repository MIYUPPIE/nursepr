defmodule NursePrep.Repo.Migrations.AddEmailToUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    alter table(:users) do
      modify :phone, :string, null: true, from: {:string, null: false}
      add :email, :citext
    end

    create unique_index(:users, [:email])

    create constraint(:users, :phone_or_email_present,
             check: "phone IS NOT NULL OR email IS NOT NULL"
           )
  end
end
