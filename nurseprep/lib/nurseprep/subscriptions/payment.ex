defmodule NursePrep.Subscriptions.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending success failed abandoned)

  schema "payments" do
    field :paystack_reference, :string
    field :amount_kobo, :integer
    field :currency, :string, default: "NGN"
    field :status, :string, default: "pending"
    field :paid_at, :utc_datetime

    belongs_to :user, NursePrep.Accounts.User
    belongs_to :subscription, NursePrep.Subscriptions.Subscription

    timestamps(type: :utc_datetime)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :user_id,
      :subscription_id,
      :paystack_reference,
      :amount_kobo,
      :currency,
      :status,
      :paid_at
    ])
    |> validate_required([:user_id, :paystack_reference, :amount_kobo, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:subscription_id)
    |> unique_constraint(:paystack_reference)
  end
end
