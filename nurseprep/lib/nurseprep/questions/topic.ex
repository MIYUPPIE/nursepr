defmodule NursePrep.Questions.Topic do
  use Ecto.Schema
  import Ecto.Changeset

  schema "topics" do
    field :name, :string
    field :slug, :string

    belongs_to :subject, NursePrep.Questions.Subject
    has_many :questions, NursePrep.Questions.Question

    timestamps(type: :utc_datetime)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:name, :slug, :subject_id])
    |> validate_required([:name, :slug, :subject_id])
    |> foreign_key_constraint(:subject_id)
    |> unique_constraint(:slug, name: :topics_subject_id_slug_index)
  end
end
