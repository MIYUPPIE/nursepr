defmodule NursePrep.Whatsapp.WhatsappSession do
  @moduledoc """
  Durable backing store for `NursePrep.Whatsapp.Session` GenServer state.
  The GenServer is the hot path; this table exists purely so a node
  restart or process crash doesn't lose an in-progress WhatsApp quiz —
  `Session.init/1` rehydrates from here if present.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "whatsapp_sessions" do
    field :phone, :string
    field :state, :map, default: %{}
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:phone, :state, :expires_at])
    |> validate_required([:phone, :state, :expires_at])
    |> unique_constraint(:phone)
  end
end
