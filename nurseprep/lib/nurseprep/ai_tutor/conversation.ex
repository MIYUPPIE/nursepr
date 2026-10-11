defmodule NursePrep.AiTutor.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_conversations" do
    field :channel, :string, default: "web"
    field :status, :string, default: "active"
    field :started_at, :utc_datetime
    field :last_message_at, :utc_datetime

    belongs_to :user, NursePrep.Accounts.User

    has_many :messages, NursePrep.AiTutor.Message,
      foreign_key: :conversation_id,
      preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_id, :channel, :status, :started_at, :last_message_at])
    |> validate_required([:user_id, :channel, :status, :started_at])
    |> validate_inclusion(:channel, ~w(web whatsapp telegram))
    |> validate_inclusion(:status, ~w(active archived))
    |> foreign_key_constraint(:user_id)
  end
end
