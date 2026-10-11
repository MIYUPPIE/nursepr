defmodule NursePrep.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending active expired cancelled)

  def statuses, do: @statuses

  schema "subscriptions" do
    field :plan, :string, default: "premium_monthly"
    field :status, :string, default: "pending"
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :paystack_customer_code, :string
    field :paystack_subscription_code, :string
    field :cancel_at_period_end, :boolean, default: false

    belongs_to :user, NursePrep.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :plan,
      :status,
      :current_period_start,
      :current_period_end,
      :paystack_customer_code,
      :paystack_subscription_code,
      :cancel_at_period_end
    ])
    |> validate_required([:user_id, :plan, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :subscriptions_one_active_per_user_index)
  end
end
