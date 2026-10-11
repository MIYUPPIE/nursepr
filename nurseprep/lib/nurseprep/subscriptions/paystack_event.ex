defmodule NursePrep.Subscriptions.PaystackEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "paystack_events" do
    field :idempotency_key, :string
    field :event_type, :string
    field :payload, :map
    field :processed_at, :utc_datetime
    field :status, :string, default: "received"

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:idempotency_key, :event_type, :payload, :processed_at, :status])
    |> validate_required([:idempotency_key, :event_type, :payload])
    |> unique_constraint(:idempotency_key)
  end
end
