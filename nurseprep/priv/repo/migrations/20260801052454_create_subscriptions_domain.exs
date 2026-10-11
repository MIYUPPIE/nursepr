defmodule NursePrep.Repo.Migrations.CreateSubscriptionsDomain do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :plan, :string, null: false, default: "premium_monthly"
      add :status, :string, null: false, default: "pending"
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      add :paystack_customer_code, :string
      add :paystack_subscription_code, :string
      add :cancel_at_period_end, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:subscriptions, [:user_id])

    create unique_index(:subscriptions, [:user_id],
             where: "status = 'active'",
             name: :subscriptions_one_active_per_user_index
           )

    create table(:payments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :subscription_id, references(:subscriptions, on_delete: :nilify_all)
      add :paystack_reference, :string, null: false
      add :amount_kobo, :integer, null: false
      add :currency, :string, null: false, default: "NGN"
      add :status, :string, null: false, default: "pending"
      add :paid_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payments, [:paystack_reference])
    create index(:payments, [:user_id])

    create table(:paystack_events) do
      add :idempotency_key, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false
      add :processed_at, :utc_datetime
      add :status, :string, null: false, default: "received"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:paystack_events, [:idempotency_key])
  end
end
