defmodule NursePrep.Questions do
  @moduledoc """
  Public API for the question bank: subjects, topics, questions, options,
  explanations, and the human review queue that gates everything before it's
  answerable by a student. Nothing outside this module should reach into
  `NursePrep.Questions.*` schemas directly.
  """

  import Ecto.Query, warn: false

  alias NursePrep.Repo

  alias NursePrep.Questions.{
    Subject,
    Topic,
    Question,
    Option,
    Explanation,
    QuestionReview
  }

  # -- Subjects / topics -------------------------------------------------------

  def list_subjects, do: Repo.all(from s in Subject, order_by: s.name)

  def get_subject!(id), do: Repo.get!(Subject, id)
  def get_subject_by_slug(slug), do: Repo.get_by(Subject, slug: slug)

  def create_subject(attrs) do
    %Subject{} |> Subject.changeset(attrs) |> Repo.insert()
  end

  def update_subject(%Subject{} = subject, attrs) do
    subject |> Subject.changeset(attrs) |> Repo.update()
  end

  @canonical_subjects [
    {"Medical-Surgical Nursing", "medical-surgical-nursing"},
    {"Maternal & Child Health", "maternal-child-health"},
    {"Community Health", "community-health"},
    {"Psychiatric Nursing", "psychiatric-nursing"},
    {"Nursing Ethics & Jurisprudence", "nursing-ethics-jurisprudence"},
    {"Anatomy & Physiology", "anatomy-physiology"},
    {"Pharmacology", "pharmacology"},
    {"Nursing Fundamentals", "nursing-fundamentals"}
  ]

  @doc """
  Seeds the canonical NMCN subject areas (per the founder's proposal) —
  idempotent, safe to call repeatedly. Called from `priv/repo/seeds.exs`
  in dev and `NursePrep.Release.seed_subjects/0` in production, so the
  list lives here once rather than duplicated in both callers.

  Topics are deliberately NOT seeded here — added later, either by hand in
  the admin UI or as a byproduct of AI-assisted tagging during question
  review; seeding them here would be guessing.
  """
  def seed_canonical_subjects do
    for {name, slug} <- @canonical_subjects do
      case get_subject_by_slug(slug) do
        nil -> create_subject(%{name: name, slug: slug})
        existing -> {:ok, existing}
      end
    end
  end

  def list_topics(subject_id) do
    Repo.all(from t in Topic, where: t.subject_id == ^subject_id, order_by: t.name)
  end

  def create_topic(attrs) do
    %Topic{} |> Topic.changeset(attrs) |> Repo.insert()
  end

  def update_topic(%Topic{} = topic, attrs) do
    topic |> Topic.changeset(attrs) |> Repo.update()
  end

  @doc "Count of questions live for practice/exams. Powers the marketing homepage stat strip."
  def count_published_questions do
    Repo.aggregate(from(q in Question, where: q.status == "published"), :count)
  end

  # -- Questions ----------------------------------------------------------------

  @doc """
  Lists questions filtered by any combination of `:status`, `:subject_id`,
  `:topic_id`, `:has_image`, and `:question_type`. Used by the admin question
  index; unfiltered by default is deliberately *not* exposed here (would be
  every ingested question at once)-callers pass filters.
  """
  @questions_per_page 50

  def questions_per_page, do: @questions_per_page

  @doc """
  Filtered questions, one page (#{@questions_per_page} rows) at a time —
  the question bank runs into the thousands post-ingestion, so an
  unpaginated `Repo.all` here would ship every row (and every preloaded
  option/explanation) to the browser on every filter change.
  """
  def list_questions(filters \\ %{}) do
    page = max(Map.get(filters, :page, 1), 1)

    Question
    |> apply_filters(filters)
    |> order_by([q], desc: q.inserted_at)
    |> preload([:subject, :topic, :options, :explanation])
    |> limit(^@questions_per_page)
    |> offset(^((page - 1) * @questions_per_page))
    |> Repo.all()
  end

  @doc "Total count of questions matching `filters`, for pagination controls."
  def count_questions(filters \\ %{}) do
    Question |> apply_filters(filters) |> Repo.aggregate(:count)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q -> where(q, [x], x.status == ^status)
      {:subject_id, id}, q -> where(q, [x], x.subject_id == ^id)
      {:topic_id, id}, q -> where(q, [x], x.topic_id == ^id)
      {:has_image, flag}, q -> where(q, [x], x.has_image == ^flag)
      {:question_type, type}, q -> where(q, [x], x.question_type == ^type)
      _, q -> q
    end)
  end

  def get_question!(id) do
    Question
    |> preload([:subject, :topic, :options, :explanation, :question_reviews])
    |> Repo.get!(id)
  end

  @doc "Creates a hand-authored question together with its options in one transaction."
  def create_question(attrs, options_attrs \\ []) do
    Repo.transaction(fn ->
      with {:ok, question} <- %Question{} |> Question.changeset(attrs) |> Repo.insert(),
           {:ok, _options} <- insert_options(question, options_attrs) do
        get_question!(question.id)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp insert_options(_question, []), do: {:ok, []}

  defp insert_options(question, options_attrs) do
    results =
      options_attrs
      |> Enum.with_index(1)
      |> Enum.map(fn {attrs, position} ->
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put_new("position", position)
        |> Map.put("question_id", question.id)
        |> then(&Option.changeset(%Option{}, &1))
        |> Repo.insert()
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, o} -> o end)}
      error -> error
    end
  end

  def update_question(%Question{} = question, attrs) do
    question |> Question.changeset(attrs) |> Repo.update()
  end

  @doc """
  Picks a random set of published questions for a practice/exam session.
  Draws from every published question regardless of which source-document
  section it was ingested from-NursePrep covers one board exam, not
  separate tracks.

  Only draws mcq questions that actually have a correct option marked —
  a status of "published" alone isn't a reliable guarantee of that (see
  `bulk_publish/1` and `approve_review/2`, which now enforce it going
  forward, but this guards the query itself so a student can never be
  served an unanswerable question regardless of how a bad row got here).
  """
  def random_question_set(opts) do
    limit = Keyword.fetch!(opts, :limit)

    correct_option_question_ids =
      from(o in Option, where: o.is_correct == true, select: o.question_id)

    Question
    |> where([q], q.status == "published")
    |> where([q], q.question_type == "mcq")
    |> where([q], q.id in subquery(correct_option_question_ids))
    |> maybe_filter(:subject_id, opts[:subject_id])
    |> maybe_filter(:topic_id, opts[:topic_id])
    |> order_by(fragment("RANDOM()"))
    |> limit(^limit)
    |> preload(:options)
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :subject_id, id), do: where(query, [q], q.subject_id == ^id)
  defp maybe_filter(query, :topic_id, id), do: where(query, [q], q.topic_id == ^id)

  # -- Review queue ---------------------------------------------------------------

  def list_pending_reviews(review_type \\ nil) do
    QuestionReview
    |> where([r], r.status == "pending")
    |> then(fn q -> if review_type, do: where(q, [r], r.review_type == ^review_type), else: q end)
    # `inserted_at` alone isn't a stable sort key: it's second-precision, so
    # rows created within the same second (routine under any real load, and
    # in tests) tie and Postgres doesn't guarantee insertion order for ties.
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> preload([:ai_suggested_topic, question: [:subject, :topic, :options]])
    |> Repo.all()
  end

  def create_review(attrs) do
    %QuestionReview{} |> QuestionReview.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Pending `ingestion_cleanup` reviews with no AI suggestion yet — what
  `Questions.Workers.AiCleanupWorker`'s fan-out enqueues jobs for. Ordered
  oldest-first so a repeatedly-triggered batch works through the backlog
  in order rather than re-picking the same recent rows.
  """
  def list_ai_cleanup_candidates(limit \\ 25) do
    QuestionReview
    |> where(
      [r],
      r.status == "pending" and r.review_type == "ingestion_cleanup" and
        is_nil(r.ai_suggested_stem)
    )
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> limit(^limit)
    |> preload(question: [:subject, :topic])
    |> Repo.all()
  end

  @doc "Text block of every subject/topic pair, for the AI cleanup prompt's taxonomy list."
  def taxonomy_for_prompt do
    Topic
    |> preload(:subject)
    |> Repo.all()
    |> Enum.map_join("\n", fn t ->
      "subject_id=#{t.subject_id} topic_id=#{t.id} — #{t.subject.name} > #{t.name}"
    end)
  end

  @doc "Writes an AI cleanup suggestion onto a review row. Never touches the live question — a human still has to accept it."
  def store_ai_suggestion(%QuestionReview{} = review, attrs) do
    review |> QuestionReview.changeset(attrs) |> Repo.update()
  end

  @doc """
  Accepts a review's AI suggestion: copies the suggested stem/subject/topic
  onto the actual question, then approves the review (publishing the
  question if this was its last pending review) — the "accept" side of
  ReviewQueueLive's accept/edit/reject flow.
  """
  def accept_ai_suggestion(%QuestionReview{} = review, reviewer_id) do
    Repo.transaction(fn ->
      question_attrs =
        %{}
        |> maybe_put("stem", review.ai_suggested_stem)
        |> maybe_put("subject_id", review.ai_suggested_subject_id)
        |> maybe_put("topic_id", review.ai_suggested_topic_id)

      if question_attrs != %{} do
        {:ok, _} =
          Question
          |> Repo.get!(review.question_id)
          |> Question.changeset(question_attrs)
          |> Repo.update()
      end

      case approve_review(review, reviewer_id) do
        {:ok, review} -> review
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Approves a review: marks it approved and, if this was the last pending
  review for the question, publishes it.

  Refuses (`{:error, :no_correct_option}`) for an mcq question with no
  option marked `is_correct`-approving used to just publish whatever was
  there, which is how a `flagged_malformed` (mismatched/missing answer key)
  question could get approved and go live still unanswerable. Fix the
  question's options (or reject the review) before approving.
  """
  def approve_review(%QuestionReview{} = review, reviewer_id, attrs \\ %{}) do
    if unanswerable_mcq?(review.question_id) do
      {:error, :no_correct_option}
    else
      string_keyed_attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

      Repo.transaction(fn ->
        {:ok, review} =
          review
          |> QuestionReview.changeset(
            Map.merge(string_keyed_attrs, %{"status" => "approved", "reviewer_id" => reviewer_id})
          )
          |> Repo.update()

        maybe_publish(review.question_id)
        review
      end)
    end
  end

  defp unanswerable_mcq?(question_id) do
    question = Question |> Repo.get!(question_id) |> Repo.preload(:options)
    question.question_type == "mcq" and not Enum.any?(question.options, & &1.is_correct)
  end

  def reject_review(%QuestionReview{} = review, reviewer_id, notes) do
    review
    |> QuestionReview.changeset(%{
      "status" => "rejected",
      "reviewer_id" => reviewer_id,
      "reviewer_notes" => notes
    })
    |> Repo.update()
  end

  defp maybe_publish(question_id) do
    pending_count =
      Repo.aggregate(
        from(r in QuestionReview, where: r.question_id == ^question_id and r.status == "pending"),
        :count
      )

    if pending_count == 0 do
      question = Repo.get!(Question, question_id)

      question
      |> Question.changeset(%{
        "status" => "published",
        "published_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()
    end
  end

  @doc "Question-status KPI tiles for `Admin.DashboardLive`."
  def admin_dashboard_stats do
    counts =
      Repo.all(from q in Question, group_by: q.status, select: {q.status, count(q.id)})
      |> Map.new()

    %{
      pending_reviews:
        Repo.aggregate(from(r in QuestionReview, where: r.status == "pending"), :count),
      published_questions: Map.get(counts, "published", 0),
      draft_questions: Map.get(counts, "draft", 0) + Map.get(counts, "pending_review", 0),
      flagged_questions: Map.get(counts, "flagged_manual_review", 0)
    }
  end

  @doc """
  Pending review counts grouped by `review_type`, in `QuestionReview.review_types/0`
  order (rather than count order) so the dashboard's "needs attention" list
  doesn't reshuffle itself between refreshes-only types with at least one
  pending review are included.
  """
  def pending_reviews_by_type do
    counts =
      Repo.all(
        from r in QuestionReview,
          where: r.status == "pending",
          group_by: r.review_type,
          select: {r.review_type, count(r.id)}
      )
      |> Map.new()

    for type <- QuestionReview.review_types(),
        count = Map.get(counts, type, 0),
        count > 0,
        do: %{review_type: type, count: count}
  end

  @doc """
  The last `limit` review decisions (approved or rejected), newest first-the
  "recent activity" feed on `Admin.DashboardLive`. Preloads the reviewer and
  question (with subject) so the feed can render "who decided what" without
  another round-trip.

  Orders by `updated_at, id` (both descending), not `updated_at` alone-same
  reasoning as `list_pending_reviews/1`'s sort key: `updated_at` is
  second-precision, so two decisions made within the same second (routine
  when a reviewer works through a batch) would otherwise tie and sort
  unpredictably.
  """
  def recent_review_decisions(limit \\ 8) do
    QuestionReview
    |> where([r], r.status in ["approved", "rejected"])
    |> order_by([r], desc: r.updated_at, desc: r.id)
    |> limit(^limit)
    |> preload([:reviewer, question: :subject])
    |> Repo.all()
  end

  @doc """
  Publishes every question in `question_ids` that has cleared review —
  mirrors `maybe_publish/1`'s per-question pending-review gate, applied in
  bulk. Anything still carrying a pending review is skipped rather than
  force-published; the previous unconditional version is how ~2,850
  ingested-but-unreviewed questions (1,376 of them with no correct option
  marked) ended up "published" and unanswerable in practice mode.

  Returns `{:ok, %{published: n, skipped: m}}`.
  """
  def bulk_publish(question_ids) do
    pending_ids =
      from(r in QuestionReview,
        where: r.question_id in ^question_ids and r.status == "pending",
        select: r.question_id,
        distinct: true
      )
      |> Repo.all()
      |> MapSet.new()

    publishable_ids = Enum.reject(question_ids, &(&1 in pending_ids))

    {count, _} =
      Question
      |> where([q], q.id in ^publishable_ids)
      |> Repo.update_all(
        set: [status: "published", published_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    {:ok, %{published: count, skipped: MapSet.size(pending_ids)}}
  end

  def bulk_flag(question_ids, reason) when is_binary(reason) do
    {count, _} =
      Question
      |> where([q], q.id in ^question_ids)
      |> Repo.update_all(set: [status: "flagged_manual_review"])

    {:ok, count}
  end

  @repair_note "Reopened by Questions.repair_wrongly_published_broken_questions/0: was published with no option marked correct."

  @doc """
  One-off data repair for questions that reached `status: "published"` with
  no option marked correct-the pre-fix `bulk_publish/1` and `approve_review/2`
  let this happen at scale (see their docs). Reverts each to
  `flagged_manual_review`, reopens any `approved` review on it back to
  `pending`, and creates a fresh pending `flagged_malformed` review for any
  such question that somehow has none, so every reverted question is visible
  in the review queue rather than just silently pulled from circulation.

  Idempotent: only touches questions currently `published` with a
  zero-correct-option mcq, so a second run is a no-op. Never invents or
  guesses a correct answer-that's a human call, not this function's.
  """
  def repair_wrongly_published_broken_questions do
    broken_ids =
      from(q in Question,
        left_join: o in Option,
        on: o.question_id == q.id and o.is_correct == true,
        where: q.status == "published" and q.question_type == "mcq" and is_nil(o.id),
        select: q.id
      )
      |> Repo.all()

    Repo.transaction(fn ->
      {questions_reverted, _} =
        Question
        |> where([q], q.id in ^broken_ids)
        |> Repo.update_all(set: [status: "flagged_manual_review", published_at: nil])

      {reviews_reopened, _} =
        QuestionReview
        |> where([r], r.question_id in ^broken_ids and r.status == "approved")
        |> Repo.update_all(set: [status: "pending"])

      reviewed_ids =
        from(r in QuestionReview,
          where: r.question_id in ^broken_ids,
          select: r.question_id,
          distinct: true
        )
        |> Repo.all()

      unreviewed_ids = broken_ids -- reviewed_ids

      Enum.each(unreviewed_ids, fn question_id ->
        Repo.insert!(%QuestionReview{
          question_id: question_id,
          review_type: "flagged_malformed",
          status: "pending",
          reviewer_notes: @repair_note
        })
      end)

      %{
        questions_reverted: questions_reverted,
        reviews_reopened: reviews_reopened,
        reviews_created: length(unreviewed_ids),
        question_ids: broken_ids
      }
    end)
  end

  # -- Explanations -----------------------------------------------------------

  def upsert_explanation(question_id, attrs) do
    case Repo.get_by(Explanation, question_id: question_id) do
      nil ->
        %Explanation{}
        |> Explanation.changeset(Map.put(attrs, "question_id", question_id))
        |> Repo.insert()

      existing ->
        existing |> Explanation.changeset(attrs) |> Repo.update()
    end
  end
end
