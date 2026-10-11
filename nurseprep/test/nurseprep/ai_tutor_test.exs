defmodule NursePrep.AiTutorTest do
  use NursePrep.DataCase, async: false

  import NursePrep.AccountsFixtures
  import NursePrep.AiTutorFixtures
  import NursePrep.Factory
  import NursePrep.QuizFixtures

  alias NursePrep.AiTutor
  alias NursePrep.AiTutor.{Conversation, Message}

  setup do
    stub_xai!()
    :ok
  end

  defp stub_reply(text) do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      })
    end)
  end

  test "ask/3 creates a conversation, persists both messages, and returns the reply" do
    stub_reply("Primary Health Care emphasizes community participation.")
    user = user_fixture() |> tap(&subscribe!/1)

    assert {:ok, reply} = AiTutor.ask(user, "web", "What is PHC?")
    assert reply == "Primary Health Care emphasizes community participation."

    conversation = Repo.get_by!(Conversation, user_id: user.id, channel: "web")
    messages = Repo.all(Message) |> Enum.sort_by(& &1.inserted_at)

    assert [
             %{role: "user", content: "What is PHC?"},
             %{
               role: "assistant",
               content: ^reply,
               model: "grok-4",
               tokens_input: 10,
               tokens_output: 5
             }
           ] =
             messages

    assert Enum.all?(messages, &(&1.conversation_id == conversation.id))
  end

  test "reuses the same active conversation across multiple questions" do
    stub_reply("first answer")
    user = user_fixture() |> tap(&subscribe!/1)

    {:ok, _} = AiTutor.ask(user, "web", "question one")
    conversation_after_first = AiTutor.get_or_create_active_conversation(user, "web")

    stub_reply("second answer")
    {:ok, _} = AiTutor.ask(user, "web", "question two")
    conversation_after_second = AiTutor.get_or_create_active_conversation(user, "web")

    assert conversation_after_first.id == conversation_after_second.id
    assert length(AiTutor.history(user, "web")) == 4
  end

  test "web and whatsapp channels get separate conversations for the same user" do
    stub_reply("answer")
    user = user_fixture() |> tap(&subscribe!/1)

    {:ok, _} = AiTutor.ask(user, "web", "web question")
    {:ok, _} = AiTutor.ask(user, "whatsapp", "whatsapp question")

    web_conversation = Repo.get_by!(Conversation, user_id: user.id, channel: "web")
    whatsapp_conversation = Repo.get_by!(Conversation, user_id: user.id, channel: "whatsapp")

    refute web_conversation.id == whatsapp_conversation.id
  end

  test "telegram is a valid channel too" do
    stub_reply("answer")
    user = user_fixture() |> tap(&subscribe!/1)

    {:ok, _} = AiTutor.ask(user, "telegram", "telegram question")

    assert Repo.get_by!(Conversation, user_id: user.id, channel: "telegram")
  end

  test "returns an error tuple without crashing when the Grok call fails" do
    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Plug.Conn.put_status(conn, 500) |> Req.Test.json(%{"error" => "boom"})
    end)

    user = user_fixture() |> tap(&subscribe!/1)

    assert {:error, {:http_error, 500, _}} = AiTutor.ask(user, "web", "question")
    # The user's question is still recorded even though the reply failed.
    assert Repo.get_by(Message, role: "user", content: "question")
  end

  test "rate-limits a user after the hourly cap" do
    stub_reply("answer")
    user = user_fixture() |> tap(&subscribe!/1)

    for n <- 1..20 do
      assert {:ok, _} = AiTutor.ask(user, "web", "question #{n}")
    end

    assert AiTutor.ask(user, "web", "one too many") == {:error, :rate_limited}
  end

  describe "explain_weak_areas/2" do
    test "sends a canned reply without calling Grok when there's no practice history yet" do
      user = user_fixture() |> tap(&subscribe!/1)

      assert {:ok, reply} = AiTutor.explain_weak_areas(user, "web")
      assert reply =~ "haven't answered enough practice questions"

      messages = Repo.all(Message) |> Enum.sort_by(& &1.inserted_at)

      assert [
               %{role: "user", content: "Explain my weak areas"},
               %{role: "assistant", content: ^reply}
             ] = messages
    end

    test "grounds the prompt in the user's actual weak-area accuracy and persists the exchange" do
      user = user_fixture() |> tap(&subscribe!/1)
      topic = insert(:topic, name: "Pharmacology")
      answer_topic_questions(user, topic, 10, correct_fraction: 0.2)

      stub_reply("You're missing dosage calculations-review therapeutic ranges.")

      assert {:ok, reply} = AiTutor.explain_weak_areas(user, "web")
      assert reply == "You're missing dosage calculations-review therapeutic ranges."

      [user_message, assistant_message] = Repo.all(Message) |> Enum.sort_by(& &1.inserted_at)

      assert user_message.role == "user"
      assert user_message.content =~ "Pharmacology"
      assert user_message.content =~ "20.0%"
      assert assistant_message.content == reply
    end

    test "rate-limits the same as ask/3 since it's a billed Grok call" do
      user = user_fixture() |> tap(&subscribe!/1)
      topic = insert(:topic, name: "Pharmacology")
      answer_topic_questions(user, topic, 10, correct_fraction: 0.2)
      stub_reply("study tip")

      for _ <- 1..20, do: AiTutor.ask(user, "web", "question")

      assert AiTutor.explain_weak_areas(user, "web") == {:error, :rate_limited}
    end
  end

  describe "subscription gating" do
    test "ask/3 rejects a free-tier user without ever calling Grok" do
      Req.Test.stub(NursePrep.AiTutor.GrokClient, fn _conn ->
        flunk("Grok should never be called for a free-tier user")
      end)

      user = user_fixture()

      assert AiTutor.ask(user, "web", "What is PHC?") == {:error, :subscription_required}
      # Nothing is persisted for a rejected request — a free user shouldn't
      # accumulate conversation history for a feature they can't use.
      refute Repo.get_by(Conversation, user_id: user.id)
      refute Repo.get_by(Message, content: "What is PHC?")
    end

    test "explain_weak_areas/2 rejects a free-tier user, including the no-Grok-call shortcut path" do
      Req.Test.stub(NursePrep.AiTutor.GrokClient, fn _conn ->
        flunk("Grok should never be called for a free-tier user")
      end)

      user = user_fixture()

      assert AiTutor.explain_weak_areas(user, "web") == {:error, :subscription_required}
      refute Repo.get_by(Conversation, user_id: user.id)
    end

    test "an expired subscription is treated the same as no subscription" do
      user = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      insert(:subscription, user: user, status: "active", current_period_end: period_end)

      assert AiTutor.ask(user, "web", "question") == {:error, :subscription_required}
    end

    test "a subscribed user can use the tutor" do
      stub_reply("Primary Health Care emphasizes community participation.")
      user = user_fixture() |> tap(&subscribe!/1)

      assert {:ok, _reply} = AiTutor.ask(user, "web", "What is PHC?")
    end
  end
end
