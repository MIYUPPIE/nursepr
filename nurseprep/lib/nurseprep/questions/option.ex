defmodule NursePrep.Questions.Option do
  use Ecto.Schema
  import Ecto.Changeset

  schema "options" do
    field :label, :string
    field :body, :string
    field :is_correct, :boolean, default: false
    field :position, :integer

    belongs_to :question, NursePrep.Questions.Question

    timestamps(type: :utc_datetime)
  end

  def changeset(option, attrs) do
    option
    |> cast(attrs, [:question_id, :label, :body, :is_correct, :position])
    |> validate_required([:question_id, :label, :body, :position])
    |> validate_inclusion(:label, ~w(A B C D E F))
    |> foreign_key_constraint(:question_id)
    |> unique_constraint([:question_id, :label], name: :options_question_id_label_index)
  end
end
