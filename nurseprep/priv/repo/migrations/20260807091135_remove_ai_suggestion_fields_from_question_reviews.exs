defmodule NursePrep.Repo.Migrations.RemoveAiSuggestionFieldsFromQuestionReviews do
  use Ecto.Migration

  def change do
    alter table(:question_reviews) do
      remove :ai_suggested_stem, :text
      remove :ai_suggested_subject_id, references(:subjects, on_delete: :nilify_all)
      remove :ai_suggested_topic_id, references(:topics, on_delete: :nilify_all)
      remove :ai_confidence, :float
    end
  end
end
