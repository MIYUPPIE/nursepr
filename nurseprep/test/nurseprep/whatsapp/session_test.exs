defmodule NursePrep.Whatsapp.SessionTest do
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import NursePrep.Factory
  import NursePrep.AccountsFixtures
  import Mox

  alias NursePrep.Whatsapp.{Session, WhatsappSession}
  alias NursePrep.{Accounts, Messaging, Quizzes, Repo}

  # Global mode: the actual send happens inside the Session GenServer's own
  # process (spawned dynamically by DynamicSupervisor), not the test
  # process, so per-process `allow/3` isn't practical here.
  setup :set_mox_global
  setup :verify_on_exit!

  # A fresh, unique phone per test (rather than one shared constant) —
  # Session processes are long-lived and registered by phone, so sharing a
  # single number across tests let a previous test's lingering process
  # (holding a now-torn-down sandbox connection) answer the next test's
  # messages, causing DB connection crashes and false negatives.
  #
  # Registered via `user_fixture/1` (the same real signup path the web
  # login uses) up front, since the bot no longer auto-enrolls whoever
  # texts it-every test past this point is exercising a real NursePrep
  # user, matching how the bot actually decides who it'll talk to.
  setup do
    phone = unique_user_phone()
    user = user_fixture(%{phone: phone})

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    %{phone: phone, user: user}
  end

  test "a message from an unregistered number gets no reply and creates no account" do
    phone = unique_user_phone()

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    Session.handle_message(phone, "hi")
    wait_for_cast(phone)

    refute Accounts.get_user_by_phone(phone)
    refute Repo.get_by(WhatsappSession, phone: phone)
  end

  test "a registered number gets a normal reply", %{phone: phone} do
    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, _text -> {:ok, %{}} end)

    Session.handle_message(phone, "hi")
    wait_for_cast(phone)

    assert Accounts.get_user_by_phone(phone)
  end

  test "'practice' starts a session and sends the first question", %{phone: phone} do
    insert_question_with_options()

    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice")
    assert_receive {:sent, text}, 1000
    assert text =~ "Question 1"
    assert text =~ "Reply with A, B, C, or D."
  end

  test "a redelivered webhook event (same message_id) for an answer is processed only once", %{
    phone: phone
  } do
    for _ <- 1..2, do: insert_question_with_options()

    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice", "msg-1")
    assert_receive {:sent, _question_one}, 1000

    Session.handle_message(phone, "A", "msg-2")
    assert_receive {:sent, first_feedback}, 1000
    assert_receive {:sent, second_question}, 1000
    assert second_question =~ "Question 2"

    # Evolution redelivers this exact webhook event-same message_id,
    # same "A"-a second time. It must be a no-op: no second grading, no
    # extra reply, and the quiz must not silently skip ahead to question 3.
    Session.handle_message(phone, "A", "msg-2")
    refute_receive {:sent, _anything}, 500

    {:ok, pid} = NursePrep.Whatsapp.Session.start_or_lookup(phone)
    state = :sys.get_state(pid)
    assert state.question_index == 1

    # A genuinely new message (different message_id) for the *next*
    # question must still go through normally-dedup must not wedge the
    # conversation shut.
    Session.handle_message(phone, "A", "msg-3")
    assert_receive {:sent, _next_feedback}, 1000

    assert first_feedback != second_question
  end

  test "answering advances to feedback, persists the answer, and continues the session", %{
    phone: phone
  } do
    question = insert_question_with_options()
    correct = Enum.find(question.options, & &1.is_correct)

    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice")
    assert_receive {:sent, _question_text}, 1000

    Session.handle_message(phone, correct.label)
    assert_receive {:sent, feedback}, 1000
    assert feedback =~ "Correct!"

    assert_receive {:sent, summary}, 1000
    assert summary =~ "Session complete!"
    assert summary =~ "1/1"
  end

  test "state survives a process restart (crash recovery via whatsapp_sessions)", %{phone: phone} do
    insert_question_with_options()
    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, _text -> {:ok, %{}} end)

    Session.handle_message(phone, "practice")
    wait_for_cast(phone)

    assert %WhatsappSession{state: %{"awaiting" => "answer"}} =
             Repo.get_by(WhatsappSession, phone: phone)

    {:ok, pid} = Session.start_or_lookup(phone)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

    # The test's own monitor firing doesn't guarantee the Registry (which
    # monitors independently) has finished unregistering the old name yet,
    # so a `start_or_lookup` right after can still race and hand back the
    # dying pid via `already_started`. Poll until a genuinely live process
    # answers instead of assuming immediate consistency.
    new_pid = wait_until_alive(phone)
    assert :sys.get_state(new_pid).awaiting == :answer
  end

  defp wait_until_alive(phone, attempts \\ 50) do
    {:ok, pid} = Session.start_or_lookup(phone)

    if Process.alive?(pid) do
      pid
    else
      Process.sleep(10)
      wait_until_alive(phone, attempts - 1)
    end
  end

  test "'ask <question>' is handed to the AI tutor", %{phone: phone} do
    user = user_fixture(phone: phone) |> tap(&subscribe!/1)

    Session.handle_message(phone, "ask what is beneficence in nursing ethics?")
    wait_for_cast(phone)

    assert_enqueued(
      worker: NursePrep.AiTutor.Workers.TutorWorker,
      args: %{
        "user_id" => user.id,
        "identity" => phone,
        "question" => "what is beneficence in nursing ethics?"
      }
    )
  end

  test "'ask <question>' from a free-tier user gets a paywall reply instead", %{phone: phone} do
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "ask what is beneficence in nursing ethics?")
    assert_receive {:sent, reply}, 1000

    assert reply =~ "Premium feature"
    refute_enqueued(worker: NursePrep.AiTutor.Workers.TutorWorker)
  end

  test "an unrecognized message with no active quiz gets a guidance nudge, never the AI tutor",
       %{phone: phone} do
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "what is beneficence in nursing ethics?")
    assert_receive {:sent, reminder}, 1000

    assert reminder =~ "ask <your question>"
    refute_enqueued(worker: NursePrep.AiTutor.Workers.TutorWorker)
  end

  test "'weak areas' enqueues the AI tutor's weak-area explanation job", %{phone: phone} do
    user = user_fixture(phone: phone) |> tap(&subscribe!/1)

    Session.handle_message(phone, "weak areas")
    wait_for_cast(phone)

    assert_enqueued(
      worker: NursePrep.AiTutor.Workers.TutorWorker,
      args: %{"user_id" => user.id, "identity" => phone, "kind" => "weak_areas"}
    )
  end

  test "'weak areas' from a free-tier user gets a paywall reply instead", %{phone: phone} do
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "weak areas")
    assert_receive {:sent, reply}, 1000

    assert reply =~ "Premium feature"
    refute_enqueued(worker: NursePrep.AiTutor.Workers.TutorWorker)
  end

  test "unrecognized text mid-quiz gets an answer-format reminder instead of hitting the AI tutor",
       %{phone: phone} do
    insert_question_with_options()
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice")
    assert_receive {:sent, _question_text}, 1000

    Session.handle_message(phone, "what's the weather like")
    assert_receive {:sent, reminder}, 1000

    assert reminder =~ "Please reply with A, B, C, or D"
    refute_enqueued(worker: NursePrep.AiTutor.Workers.TutorWorker)
  end

  test "'subscribe' sends a real Paystack checkout link", %{phone: phone} do
    # The actual HTTP call happens inside the Session GenServer's own
    # process, not the test process-same reason EvolutionClient uses
    # `set_mox_global` above instead of per-process `allow/3`. Both the
    # shared Req.Test mode and the :paystack config must be reset on exit —
    # left on, they leaked into later tests as an intermittent "cannot find
    # mock/stub" crash whenever one of those ran without its own stub.
    previous_paystack_config = Application.get_env(:nurseprep, :paystack)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Application.put_env(:nurseprep, :paystack, previous_paystack_config)
    end)

    Application.put_env(:nurseprep, :paystack,
      secret_key: "test-secret",
      public_key: "test-public",
      plug: {Req.Test, NursePrep.Subscriptions.PaystackClient}
    )

    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{
          "authorization_url" => "https://paystack.test/pay/abc",
          "access_code" => "abc",
          "reference" => "ref-1"
        }
      })
    end)

    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "subscribe")
    assert_receive {:sent, text}, 1000

    assert text =~ "Upgrade to NursePrep Premium"
    assert text =~ "https://paystack.test/pay/abc"
  end

  test "'subscribe' falls back to a friendly message when Paystack is unreachable", %{
    phone: phone
  } do
    previous_paystack_config = Application.get_env(:nurseprep, :paystack)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Application.put_env(:nurseprep, :paystack, previous_paystack_config)
    end)

    Application.put_env(:nurseprep, :paystack,
      secret_key: "test-secret",
      public_key: "test-public",
      plug: {Req.Test, NursePrep.Subscriptions.PaystackClient}
    )

    Req.Test.stub(NursePrep.Subscriptions.PaystackClient, fn conn ->
      Plug.Conn.put_status(conn, 500) |> Req.Test.json(%{})
    end)

    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "subscribe")
    assert_receive {:sent, text}, 1000

    assert text =~ "aren't available right now"
  end

  test "'exam' without an active subscription sends the paywall message and starts nothing",
       %{phone: phone} do
    insert_question_with_options()
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "exam")
    assert_receive {:sent, text}, 1000
    wait_for_cast(phone)

    assert text =~ "Premium feature"
    session = Repo.get_by(WhatsappSession, phone: phone)
    assert session.state["quiz_session_id"] == nil
    assert session.state["awaiting"] != "answer"
  end

  test "'exam' with an active subscription but no profile starts right away",
       %{phone: phone, user: user} do
    insert_question_with_options()
    insert(:subscription, user: user, status: "active", current_period_end: future())

    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "exam")

    assert_receive {:sent, intro}, 1000
    assert intro =~ "Starting your"

    assert_receive {:sent, question}, 1000
    assert question =~ "Question 1"
  end

  test "'stats' sends readiness/streak/accuracy/answered", %{phone: phone} do
    question = insert_question_with_options()
    correct = Enum.find(question.options, & &1.is_correct)
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice")
    assert_receive {:sent, _question_text}, 1000
    Session.handle_message(phone, correct.label)
    assert_receive {:sent, _feedback}, 1000
    assert_receive {:sent, _summary}, 1000

    Session.handle_message(phone, "stats")
    assert_receive {:sent, text}, 1000

    assert text =~ "Your stats"
    assert text =~ "Streak:"
    assert text =~ "Accuracy: 100%"
    assert text =~ "Questions answered: 1"
  end

  test "'leaderboard' with no ranked activity sends a friendly empty message", %{phone: phone} do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "leaderboard")
    assert_receive {:sent, text}, 1000

    assert text =~ "This week's leaderboard"
    assert text =~ "no ranked activity yet"
  end

  test "'leaderboard all time' scopes to all-time", %{phone: phone} do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "leaderboard all time")
    assert_receive {:sent, text}, 1000

    assert text =~ "All-time leaderboard"
  end

  test "'menu' lists every section of the app, matching the web nav", %{phone: phone} do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "menu")
    assert_receive {:sent, text}, 1000

    assert text =~ "practice"
    assert text =~ "exam"
    assert text =~ "stats"
    assert text =~ "leaderboard"
    assert text =~ "AI Tutor"
    assert text =~ "profile"
    assert text =~ "subscribe"
  end

  test "'profile' with no profile set up points to the settings page", %{phone: phone} do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "profile")
    assert_receive {:sent, text}, 1000

    assert text =~ "haven't set up your profile"
    assert text =~ "/users/settings"
  end

  test "'profile' shows the saved profile details", %{phone: phone, user: user} do
    {:ok, _} =
      NursePrep.Accounts.create_profile(user.id, %{
        "full_name" => "Ada Nurse",
        "school" => "UNILAG School of Nursing"
      })

    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "profile")
    assert_receive {:sent, text}, 1000

    assert text =~ "Ada Nurse"
    assert text =~ "UNILAG School of Nursing"
    assert text =~ "/users/settings"
  end

  test "the question header names the subject", %{phone: phone} do
    subject = insert(:subject, name: "Pharmacology")
    insert_question_with_options(subject: subject)

    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(phone, "practice")
    assert_receive {:sent, text}, 1000

    assert text =~ "Question 1/1-Pharmacology"
  end

  describe "practice-mode feedback" do
    test "a wrong answer shows the correct option's actual text, not just its letter", %{
      phone: phone
    } do
      question = insert_question_with_options()
      wrong = Enum.find(question.options, &(!&1.is_correct))
      correct = Enum.find(question.options, & &1.is_correct)

      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question_text}, 1000

      Session.handle_message(phone, wrong.label)
      assert_receive {:sent, feedback}, 1000

      assert feedback =~ "Not quite"
      assert feedback =~ "#{correct.label}. #{correct.body}"

      assert_receive {:sent, _summary}, 1000
    end

    test "shows no explanation line when the question has none-never generates one on the fly",
         %{phone: phone} do
      question = insert_question_with_options()
      correct = Enum.find(question.options, & &1.is_correct)

      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question_text}, 1000

      Session.handle_message(phone, correct.label)
      assert_receive {:sent, feedback}, 1000

      refute feedback =~ "💡"
      refute NursePrep.Questions.get_question!(question.id).explanation

      assert_receive {:sent, _summary}, 1000
    end

    test "shows an existing explanation when one was already written", %{phone: phone} do
      question = insert_question_with_options()
      correct = Enum.find(question.options, & &1.is_correct)

      {:ok, _} =
        NursePrep.Questions.upsert_explanation(question.id, %{
          "body" => "Already reviewed and cached.",
          "generated_by" => "human"
        })

      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question_text}, 1000

      Session.handle_message(phone, correct.label)
      assert_receive {:sent, feedback}, 1000

      assert feedback =~ "💡 Already reviewed and cached."

      assert_receive {:sent, _summary}, 1000
    end
  end

  describe "exam-mode feedback" do
    test "never reveals correct/incorrect per question", %{phone: phone, user: user} do
      for _ <- 1..2, do: insert_question_with_options()
      insert(:subscription, user: user, status: "active", current_period_end: future())

      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "exam")
      assert_receive {:sent, _intro}, 1000
      assert_receive {:sent, _question1}, 1000

      Session.handle_message(phone, "A")
      assert_receive {:sent, ack}, 1000

      refute ack =~ "Correct"
      refute ack =~ "Not quite"
      assert ack =~ "Answer recorded"

      # One question per message-the ack and the next question are
      # separate sends, not one bundled blob.
      refute ack =~ "Question 2/2"
      assert_receive {:sent, next_question}, 1000
      assert next_question =~ "Question 2/2"
    end

    test "the session-complete message links to the web results page", %{
      phone: phone,
      user: user
    } do
      insert_question_with_options()
      insert(:subscription, user: user, status: "active", current_period_end: future())

      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "exam")
      assert_receive {:sent, _intro}, 1000
      assert_receive {:sent, _question}, 1000

      Session.handle_message(phone, "A")
      assert_receive {:sent, summary}, 1000

      assert summary =~ "Session complete!"
      assert summary =~ "/results"
    end

    test "answering after the exam clock expired submits it and tells the student, instead of silently recording the answer",
         %{phone: phone, user: user} do
      insert_question_with_options()
      insert(:subscription, user: user, status: "active", current_period_end: future())
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "exam")
      assert_receive {:sent, _intro}, 1000
      assert_receive {:sent, _question}, 1000
      wait_for_cast(phone)

      quiz_session_id = Repo.get_by(WhatsappSession, phone: phone).state["quiz_session_id"]

      past = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)

      Quizzes.get_session!(quiz_session_id)
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      Session.handle_message(phone, "A")
      assert_receive {:sent, text}, 1000
      wait_for_cast(phone)

      assert text =~ "Time's up"
      assert text =~ "/results"

      session = Quizzes.get_session!(quiz_session_id)
      assert session.status == "expired"
      refute Enum.at(session.quiz_answers, 0).selected_option_id

      whatsapp_session = Repo.get_by(WhatsappSession, phone: phone)
      refute whatsapp_session.state["quiz_session_id"]
    end
  end

  describe "pause/resume/stop" do
    test "'pause' with no active session gets a friendly nudge instead of erroring", %{
      phone: phone
    } do
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "pause")
      assert_receive {:sent, text}, 1000

      assert text =~ "Nothing to pause"
    end

    test "'resume' with no active session gets a friendly nudge", %{phone: phone} do
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "resume")
      assert_receive {:sent, text}, 1000

      assert text =~ "Nothing paused"
    end

    test "'stop' with no active session still confirms and explains how to come back", %{
      phone: phone
    } do
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "stop")
      assert_receive {:sent, text}, 1000

      assert text =~ "Stopped"
      assert text =~ "\"nurseprep\" or \"start\""
    end

    test "'pause' mid-quiz saves progress and stops treating replies as answers", %{phone: phone} do
      for _ <- 1..3, do: insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question1}, 1000

      Session.handle_message(phone, "pause")
      assert_receive {:sent, text}, 1000
      assert text =~ "Paused on question 1/3"
      refute text =~ "exam clock"

      wait_for_cast(phone)
      session = Repo.get_by(WhatsappSession, phone: phone)
      assert session.state["quiz_session_id"]
      assert session.state["awaiting"] != "answer"

      # A stray "a" while paused must not be silently scored as an answer.
      Session.handle_message(phone, "a")
      assert_receive {:sent, reminder}, 1000
      assert reminder =~ "practice"
    end

    test "pausing twice reports the already-paused state instead of repeating the pause message",
         %{phone: phone} do
      insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question}, 1000

      Session.handle_message(phone, "pause")
      assert_receive {:sent, first}, 1000
      assert first =~ "Paused on question 1"

      Session.handle_message(phone, "pause")
      assert_receive {:sent, second}, 1000
      assert second =~ "Already paused"
    end

    test "'resume' re-sends the current question and lets the student answer again", %{
      phone: phone
    } do
      for _ <- 1..2, do: insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, original_question}, 1000

      Session.handle_message(phone, "pause")
      assert_receive {:sent, _paused}, 1000

      Session.handle_message(phone, "resume")
      assert_receive {:sent, resumed_question}, 1000
      assert resumed_question == original_question

      {:ok, pid} = Session.start_or_lookup(phone)
      assert :sys.get_state(pid).awaiting == :answer
    end

    test "'resume' with nothing paused (mid-quiz already) says so", %{phone: phone} do
      insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question}, 1000

      Session.handle_message(phone, "resume")
      assert_receive {:sent, text}, 1000
      assert text =~ "Already going"
    end

    test "'stop' mid-quiz marks the session abandoned and links to the results page", %{
      phone: phone
    } do
      for _ <- 1..2, do: insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question1}, 1000
      wait_for_cast(phone)

      whatsapp_session = Repo.get_by(WhatsappSession, phone: phone)
      quiz_session_id = whatsapp_session.state["quiz_session_id"]

      Session.handle_message(phone, "stop")
      assert_receive {:sent, text}, 1000
      wait_for_cast(phone)

      assert text =~ "Session stopped-0/2 answered"
      assert text =~ "/results"
      assert text =~ "\"nurseprep\" or \"start\""

      assert Quizzes.get_session!(quiz_session_id).status == "abandoned"

      session = Repo.get_by(WhatsappSession, phone: phone)
      assert session.state["quiz_session_id"] == nil
      assert session.state["awaiting"] != "answer"
      assert session.state["silenced"] == true
    end

    test "after 'stop', every message is ignored until 'nurseprep' or 'start' wakes it back up",
         %{phone: phone} do
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "stop")
      assert_receive {:sent, _stopped}, 1000

      # None of these-including commands that would normally always reply
      # -get any response while silenced.
      for text <- ["hi", "practice", "stats", "help", "menu", "ask what is beneficence?"] do
        Session.handle_message(phone, text)
      end

      wait_for_cast(phone)
      refute_receive {:sent, _anything}, 300

      session = Repo.get_by(WhatsappSession, phone: phone)
      assert session.state["silenced"] == true

      Session.handle_message(phone, "nurseprep")
      assert_receive {:sent, menu}, 1000
      wait_for_cast(phone)
      assert menu =~ "Here's everything I can do"

      session = Repo.get_by(WhatsappSession, phone: phone)
      assert session.state["silenced"] == false
    end

    test "'start' also wakes a silenced session back up", %{phone: phone} do
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "stop")
      assert_receive {:sent, _stopped}, 1000

      Session.handle_message(phone, "start")
      assert_receive {:sent, menu}, 1000
      assert menu =~ "Here's everything I can do"
    end

    test "a silenced session sends no proactive daily quiz drop", %{phone: phone, user: user} do
      insert_question_with_options()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "stop")
      assert_receive {:sent, _stopped}, 1000

      Session.send_daily_quiz(phone, user.id)
      wait_for_cast(phone)
      refute_receive {:sent, _anything}, 300
    end

    test "'stop' counts answered questions accurately", %{phone: phone} do
      question = insert_question_with_options()
      insert_question_with_options()
      correct = Enum.find(question.options, & &1.is_correct)
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "practice")
      assert_receive {:sent, _question1}, 1000

      Session.handle_message(phone, correct.label)
      assert_receive {:sent, _feedback}, 1000
      assert_receive {:sent, _question2}, 1000

      Session.handle_message(phone, "stop")
      assert_receive {:sent, text}, 1000

      assert text =~ "Session stopped-1/2 answered"
    end

    test "'pause' during an exam warns that the clock keeps running", %{phone: phone, user: user} do
      for _ <- 1..2, do: insert_question_with_options()
      insert(:subscription, user: user, status: "active", current_period_end: future())
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "exam")
      assert_receive {:sent, _intro}, 1000
      assert_receive {:sent, _question1}, 1000

      Session.handle_message(phone, "pause")
      assert_receive {:sent, text}, 1000

      assert text =~ "exam clock keeps running"
    end

    test "'resume' after the exam clock already expired tells the student and resets state", %{
      phone: phone,
      user: user
    } do
      insert_question_with_options()
      insert(:subscription, user: user, status: "active", current_period_end: future())
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(phone, "exam")
      assert_receive {:sent, _intro}, 1000
      assert_receive {:sent, _question}, 1000

      Session.handle_message(phone, "pause")
      assert_receive {:sent, _paused}, 1000
      wait_for_cast(phone)

      whatsapp_session = Repo.get_by(WhatsappSession, phone: phone)
      quiz_session_id = whatsapp_session.state["quiz_session_id"]

      # Simulate the Oban cron backstop having already auto-submitted this
      # exam as overdue while the student sat paused.
      {:ok, _} = Quizzes.submit_session(Quizzes.get_session!(quiz_session_id), "expired")

      Session.handle_message(phone, "resume")
      assert_receive {:sent, text}, 1000
      wait_for_cast(phone)

      assert text =~ "already ended (expired)"

      session = Repo.get_by(WhatsappSession, phone: phone)
      assert session.state["quiz_session_id"] == nil
    end
  end

  describe "@lid contacts (WhatsApp's privacy-ID address space)" do
    setup do
      lid = "#{System.unique_integer([:positive, :monotonic])}@lid"

      on_exit(fn ->
        case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, lid) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

          [] ->
            :ok
        end
      end)

      %{lid: lid}
    end

    test "a first message from an unlinked lid gets a one-time confirmation prompt, not silence",
         %{lid: lid} do
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(lid, "help")
      assert_receive {:sent, text}, 1000
      assert text =~ "What's the phone number on your NursePrep account?"

      wait_for_cast(lid)
      refute Accounts.get_user_by_whatsapp_lid(lid)
    end

    test "confirming a phone with no matching account nudges to sign up and stays open to retry",
         %{lid: lid} do
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(lid, "hi")
      assert_receive {:sent, _prompt}, 1000

      unregistered_phone = unique_user_phone()
      Session.handle_message(lid, unregistered_phone)
      assert_receive {:sent, text}, 1000
      assert text =~ "couldn't find a NursePrep account"

      wait_for_cast(lid)
      refute Accounts.get_user_by_whatsapp_lid(lid)

      # Still open — a second attempt with the *right* number now succeeds.
      %{phone: real_phone} = user_fixture()
      Session.handle_message(lid, real_phone)
      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(lid)
      assert Accounts.get_user_by_whatsapp_lid(lid)
    end

    test "confirming with the phone on an existing account links it and sends the help menu", %{
      lid: lid
    } do
      %{id: user_id, phone: phone} = user_fixture()
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(lid, "hey")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(lid, phone)
      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(lid)
      linked = Accounts.get_user_by_whatsapp_lid(lid)
      assert linked.id == user_id
    end

    test "once linked, a brand-new session process for the same lid resolves straight through, no re-prompt" do
      lid = "#{System.unique_integer([:positive, :monotonic])}@lid"
      %{phone: phone} = user_fixture()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, _text -> {:ok, %{}} end)

      Session.handle_message(lid, "hi")
      wait_for_cast(lid)
      Session.handle_message(lid, phone)
      wait_for_cast(lid)

      # Kill the process so the *next* message rehydrates from scratch —
      # proving the link survives via `users.whatsapp_lid`, not just
      # in-memory GenServer state carried over within one process.
      [{pid, _}] = Registry.lookup(NursePrep.Whatsapp.SessionRegistry, lid)
      DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

      insert_question_with_options()
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(lid, "practice")
      assert_receive {:sent, text}, 1000
      assert text =~ "Question 1"

      on_exit(fn ->
        case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, lid) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end

    test "texting stop during confirmation silences without linking", %{lid: lid} do
      test_pid = self()

      stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(lid, "hi")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(lid, "stop")
      assert_receive {:sent, text}, 1000
      assert text =~ "won't message you again"

      wait_for_cast(lid)
      refute Accounts.get_user_by_whatsapp_lid(lid)

      session = Repo.get_by(WhatsappSession, phone: lid)
      assert session.state["silenced"] == true
    end
  end

  describe "Telegram contacts" do
    setup do
      chat_id = System.unique_integer([:positive, :monotonic])
      identity = Messaging.tag_telegram(chat_id)

      on_exit(fn ->
        case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

          [] ->
            :ok
        end
      end)

      %{chat_id: chat_id, identity: identity}
    end

    test "a first message from an unlinked chat id gets a one-time confirmation prompt, dispatched via the Telegram client not Evolution",
         %{chat_id: chat_id, identity: identity} do
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "help")
      assert_receive {:sent, text}, 1000
      assert text =~ "phone number or email"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)
    end

    test "confirming with no matching phone/email nudges to sign up and stays open to retry", %{
      chat_id: chat_id,
      identity: identity
    } do
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "hi")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(identity, unique_user_phone())
      assert_receive {:sent, text}, 1000
      assert text =~ "Please reply with just your phone number or the email"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)

      # Still open — a second attempt with the *right* phone now succeeds.
      %{phone: real_phone} = user_fixture()
      Session.handle_message(identity, real_phone)
      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(identity)
      assert Accounts.get_user_by_telegram_chat_id(chat_id)
    end

    test "confirming with the phone on an existing account links it and sends the help menu", %{
      chat_id: chat_id,
      identity: identity
    } do
      %{id: user_id, phone: phone} = user_fixture()
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "hey")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(identity, phone)
      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(identity)
      linked = Accounts.get_user_by_telegram_chat_id(chat_id)
      assert linked.id == user_id
    end

    # The one capability the @lid flow doesn't have — a Telegram-linkable
    # student may have signed up with email only.
    test "confirming with the email on an existing account links it and sends the help menu", %{
      chat_id: chat_id,
      identity: identity
    } do
      %{id: user_id, email: email} = email_user_fixture()
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "hey")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(identity, email)
      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(identity)
      linked = Accounts.get_user_by_telegram_chat_id(chat_id)
      assert linked.id == user_id
    end

    test "a /start <token> deep link from the login page's WhatsApp-down nudge links the account and immediately sends a login OTP",
         %{chat_id: chat_id, identity: identity} do
      user = user_fixture()

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      on_exit(fn ->
        NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})
      end)

      assert {:error, :whatsapp_unavailable_no_fallback, token} = Accounts.request_otp(user.phone)

      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, linked_text}, 1000
      assert linked_text =~ "Telegram linked"

      assert_receive {:sent, otp_text}, 1000
      assert otp_text =~ "Your NursePrep login code is"

      wait_for_cast(identity)
      linked = Accounts.get_user_by_telegram_chat_id(chat_id)
      assert linked.id == user.id
    end

    # Regression coverage for the login page's other half of this flow: the
    # browser tab that showed the "link Telegram" nudge is a completely
    # different process from this one (which only exists because Telegram
    # POSTed to the webhook), so the only way it ever finds out a code went
    # out is this broadcast. Without it, the previous UX was: refresh the
    # page (losing all LiveView state), retype the phone number, and burn a
    # second otp_request rate-limit slot for a code that had already been
    # sent — see `Accounts.telegram_link_topic/1`.
    test "a /start <token> deep link broadcasts telegram_link_completed once the login OTP is actually sent",
         %{chat_id: chat_id, identity: identity} do
      user = user_fixture()

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      on_exit(fn ->
        NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})
      end)

      assert {:error, :whatsapp_unavailable_no_fallback, token} = Accounts.request_otp(user.phone)

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Phoenix.PubSub.subscribe(NursePrep.PubSub, Accounts.telegram_link_topic(token))

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:telegram_link_completed, phone}, 1000
      assert phone == user.phone
    end

    test "does not broadcast telegram_link_completed if the login OTP send itself fails",
         %{chat_id: chat_id, identity: identity} do
      user = user_fixture()

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      on_exit(fn ->
        NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})
      end)

      assert {:error, :whatsapp_unavailable_no_fallback, token} = Accounts.request_otp(user.phone)

      test_pid = self()

      # The link-confirmation send succeeds, the OTP send right after it
      # doesn't — the two-message shape `confirm_telegram_link_start/2`
      # always produces for this branch.
      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        cond do
          String.contains?(text, "Telegram linked") ->
            {:ok, %{}}

          # The login OTP attempt itself — simulate real delivery failure
          # (nothing reaches the chat), the same way a real API error
          # would.
          String.contains?(text, "Your NursePrep login code is") ->
            {:error, :simulated_failure}

          true ->
            send(test_pid, {:sent, text})
            {:ok, %{}}
        end
      end)

      Phoenix.PubSub.subscribe(NursePrep.PubSub, Accounts.telegram_link_topic(token))

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, error_text}, 1000
      assert error_text =~ "Something went wrong sending your login code"
      refute_receive {:telegram_link_completed, _phone}, 200
    end

    test "a /start <token> deep link from Settings links the account and sends the help menu, no login OTP",
         %{chat_id: chat_id, identity: identity} do
      user = user_fixture()
      token = Accounts.request_telegram_link_token(user)
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, help}, 1000
      assert help =~ "Here's everything I can do"

      wait_for_cast(identity)
      linked = Accounts.get_user_by_telegram_chat_id(chat_id)
      assert linked.id == user.id
    end

    # The actual production bug: `chat_id`/`identity` here already belongs
    # to a *different* NursePrep account (`already_linked`)-the same
    # physical Telegram account already used to test/log into one
    # account, now tapping a deep link meant for a second one. Before the
    # fix, `resolve_registered_user/1` short-circuited on the already-
    # known identity before the message text was ever inspected for a
    # link token, so this got silently treated as an ordinary (garbage)
    # command with zero feedback.
    test "a /start <token> from a chat already linked to a different account gets a clear error, not silence",
         %{chat_id: chat_id, identity: identity} do
      already_linked = user_fixture()
      {:ok, _} = Accounts.link_telegram_chat_id(already_linked, chat_id)

      other_user = user_fixture()
      token = Accounts.request_telegram_link_token(other_user)
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, text}, 1000
      assert text =~ "already linked to a different NursePrep account"

      wait_for_cast(identity)
      # Neither account moved: the already-linked one keeps chat_id, the
      # token's target account gets nothing.
      assert Accounts.get_user_by_telegram_chat_id(chat_id).id == already_linked.id
      refute Accounts.get_user!(other_user.id).telegram_chat_id
    end

    # Same bug, but reproducing the exact real-world trigger: the
    # already-linked chat is mid-quiz (`awaiting: :answer`), which is
    # what made the token text vanish into ordinary answer/command
    # parsing instead of ever reaching link-confirmation logic.
    test "a /start <token> from an already-linked chat mid-quiz is still intercepted, not treated as quiz input",
         %{chat_id: chat_id, identity: identity} do
      %{phone: phone} = user_fixture()
      insert_question_with_options()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Session.handle_message(identity, "hi")
      wait_for_cast(identity)
      Session.handle_message(identity, phone)
      wait_for_cast(identity)
      Session.handle_message(identity, "practice")
      wait_for_cast(identity)

      session_before = Repo.get_by!(WhatsappSession, phone: identity)
      assert session_before.state["awaiting"] == "answer"
      quiz_session_id_before = session_before.state["quiz_session_id"]

      other_user = user_fixture()
      token = Accounts.request_telegram_link_token(other_user)
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, text}, 1000
      assert text =~ "already linked to a different NursePrep account"

      wait_for_cast(identity)
      # The token attempt didn't touch the in-progress quiz at all-not
      # consumed as an answer, not treated as "unrecognized" either.
      session_after = Repo.get_by!(WhatsappSession, phone: identity)
      assert session_after.state["awaiting"] == "answer"
      assert session_after.state["quiz_session_id"] == quiz_session_id_before
      refute Accounts.get_user!(other_user.id).telegram_chat_id
    end

    test "an expired or bogus /start token falls back to the phone/email prompt instead of linking",
         %{chat_id: chat_id, identity: identity} do
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start not-a-real-token")

      assert_receive {:sent, text}, 1000
      assert text =~ "expired or was already used"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)
    end

    test "a bare /start with no payload still falls through to the normal confirmation prompt",
         %{chat_id: chat_id, identity: identity} do
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start")

      assert_receive {:sent, text}, 1000
      assert text =~ "phone number or email"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)
    end

    test "once linked, a brand-new session process for the same chat id resolves straight through, no re-prompt" do
      chat_id = System.unique_integer([:positive, :monotonic])
      identity = Messaging.tag_telegram(chat_id)
      %{phone: phone} = user_fixture()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Session.handle_message(identity, "hi")
      wait_for_cast(identity)
      Session.handle_message(identity, phone)
      wait_for_cast(identity)

      # Kill the process so the *next* message rehydrates from scratch —
      # proving the link survives via `users.telegram_chat_id`, not just
      # in-memory GenServer state carried over within one process.
      [{pid, _}] = Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity)
      DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

      insert_question_with_options()
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "practice")
      assert_receive {:sent, text}, 1000
      assert text =~ "Question 1"

      on_exit(fn ->
        case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end

    test "texting stop during confirmation silences without linking", %{
      chat_id: chat_id,
      identity: identity
    } do
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "hi")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(identity, "stop")
      assert_receive {:sent, text}, 1000
      assert text =~ "won't message you again"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)

      session = Repo.get_by(WhatsappSession, phone: identity)
      assert session.state["silenced"] == true
    end

    # A linked Telegram identity dispatches quiz sessions with channel:
    # "telegram" (Session.quiz_channel/1), not "whatsapp" — proves the
    # per-identity channel tagging from #7 of the plan actually threads
    # through, not just the client dispatch already covered above.
    test "a linked Telegram identity starts quiz sessions tagged with channel \"telegram\"", %{
      chat_id: chat_id,
      identity: identity
    } do
      %{phone: phone} = user_fixture()
      insert_question_with_options()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Session.handle_message(identity, "hi")
      wait_for_cast(identity)
      Session.handle_message(identity, phone)
      wait_for_cast(identity)

      Session.handle_message(identity, "practice")
      wait_for_cast(identity)

      [session] = Repo.all(Quizzes.QuizSession)
      assert session.channel == "telegram"
    end

    # The login page's Telegram tab (`Accounts.build_cold_telegram_login_token/0`)
    # mints this token with no `%User{}` on hand at all, unlike every other
    # `/start <token>` case above — so, uniquely among them, a phone/email
    # typed in reply that matches nobody is allowed to create an account
    # rather than nudging the student to sign up first.
    test "a cold login token with no matching account creates one from a typed phone number, links it, and sends a login OTP",
         %{chat_id: chat_id, identity: identity} do
      token = Accounts.build_cold_telegram_login_token()
      phone = unique_user_phone()
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")
      assert_receive {:sent, prompt}, 1000
      assert prompt =~ "phone number or email"

      refute Accounts.get_user_by_phone(phone)

      Session.handle_message(identity, phone)
      assert_receive {:sent, confirmation_text}, 1000
      assert confirmation_text =~ "Sending your NursePrep login code now"

      assert_receive {:sent, otp_text}, 1000
      assert otp_text =~ "Your NursePrep login code is"

      wait_for_cast(identity)
      user = Accounts.get_user_by_phone(phone)
      assert user
      assert user.telegram_chat_id == chat_id
    end

    test "a cold login token with no matching account creates one from a typed email address, links it, and sends a login OTP",
         %{chat_id: chat_id, identity: identity} do
      token = Accounts.build_cold_telegram_login_token()
      email = unique_user_email()
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")
      assert_receive {:sent, _prompt}, 1000

      refute Accounts.get_user_by_email(email)

      Session.handle_message(identity, email)
      assert_receive {:sent, confirmation_text}, 1000
      assert confirmation_text =~ "Sending your NursePrep login code now"

      assert_receive {:sent, otp_text}, 1000
      assert otp_text =~ "Your NursePrep login code is"

      wait_for_cast(identity)
      user = Accounts.get_user_by_email(email)
      assert user
      assert user.telegram_chat_id == chat_id
      # Created fresh with no phone at all — the OTP above must have gone
      # out over `send_telegram_login_email_otp/1`, not the phone-only path.
      refute user.phone
    end

    test "a cold login token matching an existing account links that account instead of creating a duplicate",
         %{chat_id: chat_id, identity: identity} do
      %{id: user_id, phone: phone} = user_fixture()
      before_count = Repo.aggregate(NursePrep.Accounts.User, :count)
      token = Accounts.build_cold_telegram_login_token()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Session.handle_message(identity, "/start #{token}")
      wait_for_cast(identity)
      Session.handle_message(identity, phone)
      wait_for_cast(identity)

      assert Accounts.get_user_by_telegram_chat_id(chat_id).id == user_id
      assert Repo.aggregate(NursePrep.Accounts.User, :count) == before_count
    end

    test "a cold login token from a chat already linked to an account sends a fresh login OTP immediately, no prompt",
         %{chat_id: chat_id, identity: identity} do
      %{id: user_id} = user = user_fixture()
      {:ok, _} = Accounts.link_telegram_chat_id(user, chat_id)
      token = Accounts.build_cold_telegram_login_token()
      test_pid = self()

      # Two sends here, same as the token-based `:login` flow above
      # (`deliver_cold_login_otp/3`'s confirmation line, then the OTP
      # itself)-`stub` rather than `expect` since the count isn't the
      # point of this test.
      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Session.handle_message(identity, "/start #{token}")

      assert_receive {:sent, confirmation_text}, 1000
      assert confirmation_text =~ "Sending your NursePrep login code now"

      assert_receive {:sent, otp_text}, 1000
      assert otp_text =~ "Your NursePrep login code is"

      wait_for_cast(identity)
      assert Accounts.get_user_by_telegram_chat_id(chat_id).id == user_id
    end

    # The login page's counterpart to this broadcast (see
    # `login_test.exs`) has no phone/email to subscribe on ahead of time
    # the way the old WhatsApp-down nudge did — it subscribes on the cold
    # token itself the moment the Telegram tab is shown, before anyone's
    # typed anything at all.
    test "a cold login token broadcasts telegram_cold_login_completed with the phone once the OTP is sent",
         %{chat_id: chat_id, identity: identity} do
      %{phone: phone} = user_fixture()
      token = Accounts.build_cold_telegram_login_token()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Phoenix.PubSub.subscribe(NursePrep.PubSub, Accounts.telegram_link_topic(token))

      Session.handle_message(identity, "/start #{token}")
      wait_for_cast(identity)
      Session.handle_message(identity, phone)

      assert_receive {:telegram_cold_login_completed, :phone, ^phone}, 1000
    end

    test "a cold login token broadcasts telegram_cold_login_completed with the email once the OTP is sent",
         %{chat_id: chat_id, identity: identity} do
      %{email: email} = email_user_fixture()
      token = Accounts.build_cold_telegram_login_token()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

      Phoenix.PubSub.subscribe(NursePrep.PubSub, Accounts.telegram_link_topic(token))

      Session.handle_message(identity, "/start #{token}")
      wait_for_cast(identity)
      Session.handle_message(identity, email)

      assert_receive {:telegram_cold_login_completed, :email, ^email}, 1000
    end

    test "texting stop mid cold-login silences without linking or broadcasting", %{
      chat_id: chat_id,
      identity: identity
    } do
      token = Accounts.build_cold_telegram_login_token()
      test_pid = self()

      stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      Phoenix.PubSub.subscribe(NursePrep.PubSub, Accounts.telegram_link_topic(token))

      Session.handle_message(identity, "/start #{token}")
      assert_receive {:sent, _prompt}, 1000

      Session.handle_message(identity, "stop")
      assert_receive {:sent, text}, 1000
      assert text =~ "won't message you again"

      wait_for_cast(identity)
      refute Accounts.get_user_by_telegram_chat_id(chat_id)
      refute_receive {:telegram_cold_login_completed, _kind, _identifier}, 200

      session = Repo.get_by(WhatsappSession, phone: identity)
      assert session.state["silenced"] == true
      assert session.state["pending_login_token"] == nil
    end
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

  defp wait_for_cast(phone),
    do: :sys.get_state({:via, Registry, {NursePrep.Whatsapp.SessionRegistry, phone}})
end
