defmodule NursePrep.Questions.Subject do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subjects" do
    field :name, :string
    field :slug, :string
    field :description, :string

    has_many :topics, NursePrep.Questions.Topic
    has_many :questions, NursePrep.Questions.Question

    timestamps(type: :utc_datetime)
  end

  def changeset(subject, attrs) do
    subject
    |> cast(attrs, [:name, :slug, :description])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
