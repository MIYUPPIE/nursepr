defmodule NursePrep.Repo.Migrations.RemoveExamTrackFromProfilesAndQuizSessions do
  use Ecto.Migration

  @moduledoc """
  NursePrep only ever covers the one NMCN board exam-there's no separate
  "general nurse" vs "midwife" track for a student to pick, or a session to
  be scoped to. `questions.exam_track` stays: it's the docx ingestion
  pipeline's internal provenance/idempotency key (which source-document
  section a question came from), not a user-facing choice, and dropping it
  would collide `source_section_ordinal` values that reset per source
  section across the two halves of the document.
  """

  def change do
    alter table(:profiles) do
      remove :exam_track, :string, null: false
    end

    alter table(:quiz_sessions) do
      remove :exam_track, :string
    end
  end
end
