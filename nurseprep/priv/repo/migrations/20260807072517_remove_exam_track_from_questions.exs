defmodule NursePrep.Repo.Migrations.RemoveExamTrackFromQuestions do
  use Ecto.Migration

  def up do
    drop unique_index(:questions, [:exam_track, :source_section_ordinal, :source_question_number],
           name: :questions_ingestion_idempotency_index
         )

    drop index(:questions, [:exam_track, :status])

    # DDL macros above are queued, not executed inline-force them to run
    # before the raw SQL below, which depends on the old unique index
    # already being gone.
    flush()

    renumber_sections_globally()

    alter table(:questions) do
      remove :exam_track, :string
    end

    create unique_index(
             :questions,
             [:source_section_ordinal, :source_question_number],
             name: :questions_ingestion_idempotency_index
           )
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: exam_track and each track's original section numbering can't be reconstructed"
  end

  # The old parser reset `source_section_ordinal` back to 0 at the start of
  # every exam-track section (see docx_parser.ex before this change): two
  # real, distinct questions from different tracks can share the same
  # (section_ordinal, question_number) pair once the track dimension drops
  # out of the uniqueness key-verified against live data, e.g. (5, 15)
  # exists once under each of the two tracks. Offsetting each track's
  # ordinals by the running max of the tracks that precede it (ordered by
  # each track's first `id`, i.e. real document order, since ingestion
  # persists rows in document-walk order) reproduces exactly what the new
  # monotonic-numbering parser would have produced from a single pass over
  # the same source document-without touching stem, status, options, or
  # any already-reviewed/edited content.
  defp renumber_sections_globally do
    %{rows: tracks} =
      repo().query!("""
      SELECT exam_track, max(source_section_ordinal)
      FROM questions
      GROUP BY exam_track
      ORDER BY min(id)
      """)

    Enum.reduce(tracks, 0, fn [track, max_ordinal], offset ->
      if offset > 0 do
        repo().query!(
          "UPDATE questions SET source_section_ordinal = source_section_ordinal + $1 WHERE exam_track = $2",
          [offset, track]
        )
      end

      offset + (max_ordinal || 0)
    end)
  end
end
