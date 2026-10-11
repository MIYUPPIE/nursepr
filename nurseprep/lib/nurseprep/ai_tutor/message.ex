defmodule NursePrep.AiTutor.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_messages" do
    field :role, :string
    field :content, :string
    field :model, :string
    field :tokens_input, :integer
    field :tokens_output, :integer
    field :flagged, :boolean, default: false

    belongs_to :conversation, NursePrep.AiTutor.Conversation

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :role,
      :content,
      :model,
      :tokens_input,
      :tokens_output,
      :flagged
    ])
    |> validate_required([:conversation_id, :role, :content])
    |> validate_inclusion(:role, ~w(user assistant system))
    |> foreign_key_constraint(:conversation_id)
  end
end
