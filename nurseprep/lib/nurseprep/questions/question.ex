defmodule NursePrep.Questions.Question do
  use Ecto.Schema
  import Ecto.Changeset

  @question_types ~w(mcq fill_blank diagram_label unresolved)
  @difficulties ~w(easy medium hard)
  @statuses ~w(draft pending_review approved published rejected flagged_manual_review)

  def question_types, do: @question_types
  def difficulties, do: @difficulties
  def statuses, do: @statuses

  schema "questions" do
    field :source_section_ordinal, :integer
    field :source_section_label, :string
    field :source_question_number, :integer

    field :stem, :string
    # Original, pre-cleanup text captured verbatim at ingestion time. Kept
    # forever even after `stem` is edited, so the admin review UI can always
    # diff "what we published" against "what the source actually said."
    field :raw_stem, :string

    field :question_type, :string
    field :difficulty, :string
    field :status, :string, default: "draft"
    field :has_image, :boolean, default: false
    field :image_path, :string
    field :published_at, :utc_datetime

    belongs_to :subject, NursePrep.Questions.Subject
    belongs_to :topic, NursePrep.Questions.Topic

    has_many :options, NursePrep.Questions.Option,
      on_delete: :delete_all,
      preload_order: [asc: :position]

    has_one :explanation, NursePrep.Questions.Explanation, on_delete: :delete_all
    has_many :question_reviews, NursePrep.Questions.QuestionReview, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for hand-authored questions created directly in the admin UI."
  def changeset(question, attrs) do
    question
    |> cast(attrs, [
      :subject_id,
      :topic_id,
      :stem,
      :raw_stem,
      :question_type,
      :difficulty,
      :status,
      :has_image,
      :image_path,
      :published_at
    ])
    |> validate_required([:stem, :question_type, :status])
    |> validate_inclusion(:question_type, @question_types)
    |> validate_inclusion(:difficulty, @difficulties)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:subject_id)
    |> foreign_key_constraint(:topic_id)
  end

  @doc "Changeset used only by the docx ingestion pipeline, which additionally sets provenance fields."
  def ingestion_changeset(question, attrs) do
    question
    |> changeset(attrs)
    |> cast(attrs, [:source_section_ordinal, :source_section_label, :source_question_number])
    |> validate_required([:source_section_ordinal, :source_question_number])
    |> unique_constraint([:source_section_ordinal, :source_question_number],
      name: :questions_ingestion_idempotency_index
    )
  end
end
