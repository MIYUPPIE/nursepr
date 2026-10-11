defmodule NursePrep.Questions.Workers.AiCleanupWorker do
  @moduledoc """
  AI-assisted cleanup/tagging for ingested questions — admin-triggered and
  batched from `Admin.ReviewQueueLive`, never automatic per-question during
  ingestion (that would mean thousands of uncontrolled Claude calls the
  moment a docx is ingested). Calls `LocalClaudeClient`, which shells out to
  local Claude Code rather than a hosted API-see its moduledoc for why.

  Only ever writes *suggestions* onto the `question_reviews` row
  (`ai_suggested_stem`/`ai_suggested_subject_id`/`ai_suggested_topic_id`) —
  nothing here touches the live `question` row. A human still has to
  accept, edit, or reject in the review queue; nothing auto-publishes.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 3

  require Logger

  alias NursePrep.Repo
  alias NursePrep.Questions
  alias NursePrep.Questions.QuestionReview

  @system_prompt """
  You are a content-cleanup assistant for a Nigerian nursing licensure exam \
  question bank. Questions were OCR-extracted from a scanned document and \
  contain noise: stray characters, broken words, inconsistent spacing.

  You will be given a raw question stem and a list of subject/topic pairs, \
  each with a numeric id. Reply with ONLY a JSON object — no prose, no \
  markdown code fences — shaped exactly like:

  {"cleaned_stem": "...", "subject_id": <int or null>, "topic_id": <int or null>, "confidence": <float 0.0-1.0>}

  Rules:
  - Fix OCR noise (spacing, stray punctuation, broken words, misspelled \
  medical/nursing terms) in cleaned_stem.
  - Never change the clinical or factual meaning of the question — do not \
  add, remove, or reinterpret any detail that could change which answer \
  option is correct. If you are not confident a change preserves meaning, \
  leave that part of the text unchanged.
  - If nothing needs fixing, return the stem unchanged.
  - Pick the single best-fit subject_id/topic_id from the provided list, or \
  null for either if none genuinely fits — never guess.
  - confidence is your own self-assessed confidence in this suggestion (not \
  a calibrated probability) — a human always reviews before anything is \
  applied to the live question.
  """

  @doc "The cleanup system prompt, exposed for `test/evals/ai_cleanup_eval_test.exs` to exercise the real prompt."
  def system_prompt, do: @system_prompt

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"review_id" => review_id}}) do
    review =
      QuestionReview
      |> Repo.get!(review_id)
      |> Repo.preload(question: [:subject, :topic])

    suggest_and_store(review)
  end

  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args, "limit", 25)

    Questions.list_ai_cleanup_candidates(limit)
    |> Enum.each(fn review ->
      %{review_id: review.id}
      |> new(unique: [period: 3600, keys: [:review_id]])
      |> Oban.insert()
    end)

    :ok
  end

  defp suggest_and_store(review) do
    prompt = """
    Raw stem:
    #{review.question.raw_stem || review.question.stem}

    Subjects/topics (subject_id, topic_id, subject name > topic name):
    #{Questions.taxonomy_for_prompt()}
    """

    case local_claude_client().ask(prompt, @system_prompt) do
      {:ok, %{text: text}} ->
        apply_suggestion(review, text)

      {:error, reason} ->
        Logger.warning(
          "AiCleanupWorker: local Claude call failed for review #{review.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp apply_suggestion(review, text) do
    case Jason.decode(strip_fences(text)) do
      {:ok, %{"cleaned_stem" => stem} = decoded} when is_binary(stem) ->
        {:ok, _} =
          Questions.store_ai_suggestion(review, %{
            "ai_suggested_stem" => stem,
            "ai_suggested_subject_id" => decoded["subject_id"],
            "ai_suggested_topic_id" => decoded["topic_id"],
            "ai_confidence" => decoded["confidence"]
          })

        :ok

      _ ->
        Logger.warning(
          "AiCleanupWorker: unparseable response for review #{review.id}: #{inspect(text)}"
        )

        {:error, :unparseable_response}
    end
  end

  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp local_claude_client,
    do:
      Application.get_env(:nurseprep, :local_claude_client, NursePrep.Questions.LocalClaudeClient)
end
