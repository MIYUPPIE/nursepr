defmodule NursePrep.Questions.QuestionReview do
  use Ecto.Schema
  import Ecto.Changeset

  @review_types ~w(ingestion_cleanup tagging explanation flagged_image flagged_malformed)
  @statuses ~w(pending approved rejected needs_changes)

  def review_types, do: @review_types
  def statuses, do: @statuses

  schema "question_reviews" do
    field :review_type, :string
    field :status, :string, default: "pending"
    field :reviewer_notes, :string

    # Suggestion-only-nothing here ever touches the live `question` row
    # directly. `Questions.accept_ai_suggestion/2` is the one path that
    # copies these onto the question, and only once a human calls it.
    field :ai_suggested_stem, :string
    field :ai_confidence, :float

    belongs_to :question, NursePrep.Questions.Question
    belongs_to :reviewer, NursePrep.Accounts.User, foreign_key: :reviewer_id
    belongs_to :ai_suggested_subject, NursePrep.Questions.Subject
    belongs_to :ai_suggested_topic, NursePrep.Questions.Topic

    timestamps(type: :utc_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :question_id,
      :review_type,
      :status,
      :reviewer_id,
      :reviewer_notes,
      :ai_suggested_stem,
      :ai_suggested_subject_id,
      :ai_suggested_topic_id,
      :ai_confidence
    ])
    |> validate_required([:question_id, :review_type, :status])
    |> validate_inclusion(:review_type, @review_types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:question_id)
    |> foreign_key_constraint(:reviewer_id)
    |> foreign_key_constraint(:ai_suggested_subject_id)
    |> foreign_key_constraint(:ai_suggested_topic_id)
  end
end
