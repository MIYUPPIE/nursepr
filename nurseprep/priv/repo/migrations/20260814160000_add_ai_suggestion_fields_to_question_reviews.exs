defmodule NursePrep.Repo.Migrations.AddAiSuggestionFieldsToQuestionReviews do
  use Ecto.Migration

  # Re-adds what 20260807091135_remove_ai_suggestion_fields_from_question_reviews.exs
  # dropped. That removal went out alongside `AiCleanupWorker` itself, both
  # swept up as "unused" in a bulk cleanup commit-at the time nothing had
  # ever actually ingested real content, so the worker had never run. Now
  # that ingestion is real (see mix nurseprep.ingest_questions), the fields
  # are back for the same purpose: an AI-suggested cleaned stem and
  # subject/topic tag living on the review row until a human accepts it.
  def change do
    alter table(:question_reviews) do
      add :ai_suggested_stem, :text
      add :ai_suggested_subject_id, references(:subjects, on_delete: :nilify_all)
      add :ai_suggested_topic_id, references(:topics, on_delete: :nilify_all)
      add :ai_confidence, :float
    end
  end
end
