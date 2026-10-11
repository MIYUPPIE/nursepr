defmodule NursePrep.AiTutor.Workers.TutorWorkerTest do
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import NursePrep.AccountsFixtures
  import NursePrep.AiTutorFixtures
  import Mox

  alias NursePrep.AiTutor.Workers.TutorWorker
  alias NursePrep.Messaging

  setup :verify_on_exit!

  setup do
    stub_xai!()
    :ok
  end

  test "asks the tutor and sends the reply back over WhatsApp" do
    user = user_fixture() |> tap(&NursePrep.Factory.subscribe!/1)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Here's how nursing ethics applies..."
            }
          }
        ],
        "usage" => %{}
      })
    end)

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn phone, text ->
      assert phone == user.phone
      assert text == "Here's how nursing ethics applies..."
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(TutorWorker, %{
               "user_id" => user.id,
               "identity" => user.phone,
               "question" => "Explain beneficence"
             })
  end

  test "asks the tutor and sends the reply back over Telegram, tagged with the telegram channel" do
    user = user_fixture() |> tap(&NursePrep.Factory.subscribe!/1)
    chat_id = 123_456_789
    identity = Messaging.tag_telegram(chat_id)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Telegram answer."}}],
        "usage" => %{}
      })
    end)

    expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
      assert text == "Telegram answer."
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(TutorWorker, %{
               "user_id" => user.id,
               "identity" => identity,
               "question" => "Explain beneficence"
             })

    conversation =
      NursePrep.Repo.get_by!(NursePrep.AiTutor.Conversation,
        user_id: user.id,
        channel: "telegram"
      )

    assert conversation
  end

  test "asks for a weak-area explanation and sends the reply back over WhatsApp" do
    user = user_fixture() |> tap(&NursePrep.Factory.subscribe!/1)
    topic = NursePrep.Factory.insert(:topic, name: "Pharmacology")
    NursePrep.QuizFixtures.answer_topic_questions(user, topic, 10, correct_fraction: 0.2)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Focus on dosage math."}}
        ],
        "usage" => %{}
      })
    end)

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn phone, text ->
      assert phone == user.phone
      assert text == "Focus on dosage math."
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(TutorWorker, %{
               "user_id" => user.id,
               "identity" => user.phone,
               "kind" => "weak_areas"
             })
  end

  test "sends a paywall message, never calling Grok, for a free-tier user" do
    user = user_fixture()

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn _conn ->
      flunk("Grok should never be called for a free-tier user")
    end)

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn phone, text ->
      assert phone == user.phone
      assert text =~ "Premium feature"
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(TutorWorker, %{
               "user_id" => user.id,
               "identity" => user.phone,
               "question" => "Explain beneficence"
             })
  end

  test "sends a friendly fallback message when the tutor call fails" do
    user = user_fixture() |> tap(&NursePrep.Factory.subscribe!/1)

    Req.Test.stub(NursePrep.AiTutor.GrokClient, fn conn ->
      Plug.Conn.put_status(conn, 500) |> Req.Test.json(%{})
    end)

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      assert text =~ "unavailable"
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(TutorWorker, %{
               "user_id" => user.id,
               "identity" => user.phone,
               "question" => "hi"
             })
  end
end
