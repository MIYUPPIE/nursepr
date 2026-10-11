defmodule NursePrep.Questions.Explanation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "explanations" do
    field :body, :string
    field :generated_by, :string, default: "human"
    field :approved_at, :utc_datetime

    belongs_to :question, NursePrep.Questions.Question
    belongs_to :reviewed_by, NursePrep.Accounts.User, foreign_key: :reviewed_by_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(explanation, attrs) do
    explanation
    |> cast(attrs, [:question_id, :body, :generated_by, :approved_at, :reviewed_by_user_id])
    |> validate_required([:question_id, :body, :generated_by])
    |> validate_inclusion(:generated_by, ~w(ai human))
    |> foreign_key_constraint(:question_id)
    |> foreign_key_constraint(:reviewed_by_user_id)
    |> unique_constraint(:question_id)
  end
end
