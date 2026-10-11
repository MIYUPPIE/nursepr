defmodule NursePrep.Repo.Migrations.CreateQuestionsDomain do
  use Ecto.Migration

  def change do
    create table(:subjects) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subjects, [:name])
    create unique_index(:subjects, [:slug])

    create table(:topics) do
      add :subject_id, references(:subjects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:topics, [:subject_id, :slug])

    create table(:questions) do
      add :subject_id, references(:subjects, on_delete: :nilify_all)
      add :topic_id, references(:topics, on_delete: :nilify_all)

      add :exam_track, :string, null: false
      add :source_section_ordinal, :integer
      add :source_section_label, :string
      add :source_question_number, :integer

      add :stem, :text, null: false
      add :raw_stem, :text
      add :question_type, :string, null: false
      add :difficulty, :string
      add :status, :string, null: false, default: "draft"
      add :has_image, :boolean, null: false, default: false
      add :image_path, :string
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:questions, [:status])
    create index(:questions, [:subject_id])
    create index(:questions, [:topic_id])
    create index(:questions, [:exam_track, :status])

    create unique_index(
             :questions,
             [:exam_track, :source_section_ordinal, :source_question_number],
             name: :questions_ingestion_idempotency_index
           )

    create table(:options) do
      add :question_id, references(:questions, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :body, :text, null: false
      add :is_correct, :boolean, null: false, default: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:options, [:question_id, :label])

    create table(:explanations) do
      add :question_id, references(:questions, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :generated_by, :string, null: false, default: "human"
      add :reviewed_by_user_id, references(:users, on_delete: :nilify_all)
      add :approved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:explanations, [:question_id])

    create table(:question_reviews) do
      add :question_id, references(:questions, on_delete: :delete_all), null: false
      add :review_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :ai_suggested_stem, :text
      add :ai_suggested_subject_id, references(:subjects, on_delete: :nilify_all)
      add :ai_suggested_topic_id, references(:topics, on_delete: :nilify_all)
      add :ai_confidence, :float
      add :reviewer_id, references(:users, on_delete: :nilify_all)
      add :reviewer_notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:question_reviews, [:status, :review_type])
    create index(:question_reviews, [:question_id])
  end
end
