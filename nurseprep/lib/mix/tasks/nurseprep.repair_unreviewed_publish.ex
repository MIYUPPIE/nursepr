defmodule Mix.Tasks.Nurseprep.RepairUnreviewedPublish do
  @shortdoc "Reverts published mcq questions with no correct option back into the review queue"

  @moduledoc """
  One-off fix for a `bulk_publish/1` bug (fixed in the same change as this
  task) that let questions go `status: published` without clearing their
  ingestion review-including ones ingestion had already flagged as having
  no verifiable answer key. Practice/exam mode always showed "Not quite" on
  these because no option was ever marked correct.

      mix nurseprep.repair_unreviewed_publish

  Reverts every published mcq question with zero `is_correct` options back
  to `flagged_manual_review`, reopening its review so it's visible at
  /admin/review-queue for an actual human to fix or reject. Never guesses at
  what the correct answer should be. Idempotent-safe to re-run.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, result} = NursePrep.Questions.repair_wrongly_published_broken_questions()

    Mix.shell().info("""

    Questions reverted to flagged_manual_review: #{result.questions_reverted}
    Reviews reopened (were approved):            #{result.reviews_reopened}
    Reviews created (had none):                  #{result.reviews_created}

    These are now visible at /admin/review-queue for manual fix or reject.
    """)
  end
end
