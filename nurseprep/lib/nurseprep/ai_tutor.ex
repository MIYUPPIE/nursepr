defmodule NursePrep.AiTutor do
  @moduledoc """
  Free-text nursing Q&A, backed directly by the xAI (Grok) API (see
  `GrokClient` for why this is a deliberate, scoped exception to routing
  LLM calls through local Claude Code). Every message-both sides-is
  persisted for audit, same discipline as the human-reviewed explanation
  workflow in `Questions`.
  """

  import Ecto.Query, warn: false

  alias NursePrep.Repo
  alias NursePrep.Analytics
  alias NursePrep.AiTutor.{Conversation, Message, GrokClient}

  @history_limit 20
  @rate_limit {60_000 * 60, 20}

  @weak_areas_request "Explain my weak areas"

  @doc """
  Asks the tutor a question on behalf of `user`, over `channel`
  ("web"/"whatsapp"). Returns `{:ok, reply_text}` or an error tuple —
  `{:error, :subscription_required}` for a free-tier user (the tutor is
  a Premium feature, same as timed mock exams), `{:error, :rate_limited}`
  when the per-user hourly cap is hit, since every message here is a
  billed Grok call.
  """
  def ask(user, channel, text) do
    with :ok <- require_subscription(user),
         {:allow, _count} <-
           Hammer.check_rate("ai_tutor:#{user.id}", elem(@rate_limit, 0), elem(@rate_limit, 1)) do
      conversation = get_or_create_active_conversation(user, channel)
      {:ok, _user_message} = save_message(conversation, "user", text)

      messages =
        conversation
        |> recent_messages()
        |> Enum.map(&%{role: &1.role, content: &1.content})

      case GrokClient.ask(messages) do
        {:ok, %{text: reply} = result} ->
          {:ok, _assistant_message} =
            save_message(conversation, "assistant", reply,
              model: result.model,
              tokens_input: result.tokens_input,
              tokens_output: result.tokens_output
            )

          touch_conversation(conversation)
          {:ok, reply}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :subscription_required} = error -> error
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  defp require_subscription(user) do
    if NursePrep.Subscriptions.active?(user), do: :ok, else: {:error, :subscription_required}
  end

  @doc """
  Explains `user`'s weakest topics on request, over `channel`. Grounded in
  their actual `Analytics.weak_areas/2` numbers rather than the student
  describing their own performance from memory-the model has no other
  way to know a specific student's accuracy. Persisted through the same
  conversation/history as `ask/3` so it shows up inline in both the web
  chat and the WhatsApp reply.

  Skips the Grok call entirely (deterministic, not a billed request) when
  there isn't enough practice history yet to name a weak area-the reply
  is the same every time for that case, so there's nothing for the model
  to add.
  """
  def explain_weak_areas(user, channel) do
    case require_subscription(user) do
      {:error, :subscription_required} = error -> error
      :ok -> do_explain_weak_areas(user, channel)
    end
  end

  defp do_explain_weak_areas(user, channel) do
    case Analytics.weak_areas(user, 3) do
      [] ->
        reply =
          "You haven't answered enough practice questions yet for me to spot a weak area-do a round or two of practice and ask again!"

        conversation = get_or_create_active_conversation(user, channel)
        {:ok, _} = save_message(conversation, "user", @weak_areas_request)
        {:ok, _} = save_message(conversation, "assistant", reply)
        touch_conversation(conversation)
        {:ok, reply}

      areas ->
        ask(user, channel, weak_areas_prompt(areas))
    end
  end

  defp weak_areas_prompt(areas) do
    breakdown =
      Enum.map_join(areas, "\n", fn a ->
        "- #{a.topic_name}: #{a.accuracy}% correct over #{a.attempts} attempts"
      end)

    """
    Here's my recent practice performance by topic, weakest first:
    #{breakdown}

    Explain the core concepts I'm likely getting wrong in these topics and give me a focused study tip for each.
    """
  end

  def get_or_create_active_conversation(user, channel) do
    case Repo.one(
           from c in Conversation,
             where: c.user_id == ^user.id and c.channel == ^channel and c.status == "active",
             order_by: [desc: c.inserted_at],
             limit: 1
         ) do
      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %Conversation{}
        |> Conversation.changeset(%{
          "user_id" => user.id,
          "channel" => channel,
          "status" => "active",
          "started_at" => now,
          "last_message_at" => now
        })
        |> Repo.insert!()

      conversation ->
        conversation
    end
  end

  def history(user, channel) do
    user
    |> get_or_create_active_conversation(channel)
    |> recent_messages()
  end

  defp recent_messages(conversation) do
    Repo.all(
      from m in Message,
        where: m.conversation_id == ^conversation.id,
        order_by: [desc: m.inserted_at],
        limit: @history_limit
    )
    |> Enum.reverse()
  end

  defp save_message(conversation, role, content, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      "conversation_id" => conversation.id,
      "role" => role,
      "content" => content,
      "model" => opts[:model],
      "tokens_input" => opts[:tokens_input],
      "tokens_output" => opts[:tokens_output]
    })
    |> Repo.insert()
  end

  defp touch_conversation(conversation) do
    conversation
    |> Conversation.changeset(%{
      "last_message_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end
end
