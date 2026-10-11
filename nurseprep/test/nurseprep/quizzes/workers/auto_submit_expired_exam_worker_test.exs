defmodule NursePrep.Quizzes.Workers.AutoSubmitExpiredExamWorkerTest do
  # async: false — the WhatsApp notification test drives a real
  # Whatsapp.Session GenServer through Mox global mode (the send happens
  # inside that spawned process, not the test process), same constraint
  # as Whatsapp.SessionTest.
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import NursePrep.Factory
  import NursePrep.AccountsFixtures
  import Mox

  alias NursePrep.{Accounts, Messaging, Quizzes}
  alias NursePrep.Quizzes.Workers.AutoSubmitExpiredExamWorker
  alias NursePrep.Whatsapp.{Session, WhatsappSession}

  setup :set_mox_global
  setup :verify_on_exit!

  test "expires overdue in_progress exams and leaves others untouched" do
    user = user_fixture()
    insert_question_with_options()

    {:ok, overdue} = Quizzes.start_exam_session(user)
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    overdue |> Ecto.Changeset.change(expires_at: past) |> NursePrep.Repo.update!()

    {:ok, still_active} = Quizzes.start_exam_session(user)

    assert :ok = perform_job(AutoSubmitExpiredExamWorker, %{})

    assert Quizzes.get_session!(overdue.id).status == "expired"
    assert Quizzes.get_session!(still_active.id).status == "in_progress"
  end

  test "proactively notifies a whatsapp student whose exam clock ran out, but never a web one" do
    web_user = user_fixture()
    whatsapp_phone = unique_user_phone()
    whatsapp_user = user_fixture(%{phone: whatsapp_phone})
    insert_question_with_options()

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, whatsapp_phone) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    future = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
    insert(:subscription, user: whatsapp_user, status: "active", current_period_end: future)

    # A web exam past its deadline — the client-side timer is presumed to
    # have already handled the redirect, so this must never trigger a send.
    {:ok, web_session} = Quizzes.start_exam_session(web_user)
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    web_session |> Ecto.Changeset.change(expires_at: past) |> NursePrep.Repo.update!()

    # A whatsapp exam, actually started through the session so
    # Whatsapp.Session is tracking it as the student's active exam —
    # otherwise the notification would have nothing to compare against.
    test_pid = self()

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn phone, text ->
      send(test_pid, {:sent, phone, text})
      {:ok, %{}}
    end)

    Session.handle_message(whatsapp_phone, "exam")
    assert_receive {:sent, ^whatsapp_phone, _intro}, 1000
    assert_receive {:sent, ^whatsapp_phone, _question}, 1000
    :sys.get_state({:via, Registry, {NursePrep.Whatsapp.SessionRegistry, whatsapp_phone}})

    whatsapp_session_id =
      NursePrep.Repo.get_by(WhatsappSession, phone: whatsapp_phone).state["quiz_session_id"]

    Quizzes.get_session!(whatsapp_session_id)
    |> Ecto.Changeset.change(expires_at: past)
    |> NursePrep.Repo.update!()

    assert :ok = perform_job(AutoSubmitExpiredExamWorker, %{})

    assert_receive {:sent, ^whatsapp_phone, text}, 1000
    assert text =~ "Time's up"

    refute_received {:sent, _other_phone, _text}

    assert Quizzes.get_session!(web_session.id).status == "expired"
    assert Quizzes.get_session!(whatsapp_session_id).status == "expired"

    updated = NursePrep.Repo.get_by(WhatsappSession, phone: whatsapp_phone)
    refute updated.state["quiz_session_id"]
  end

  test "proactively notifies a telegram student whose exam clock ran out, via the Telegram client" do
    chat_id = System.unique_integer([:positive, :monotonic])
    identity = Messaging.tag_telegram(chat_id)
    telegram_user = user_fixture()
    {:ok, telegram_user} = Accounts.link_telegram_chat_id(telegram_user, chat_id)
    insert_question_with_options()

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    future = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
    insert(:subscription, user: telegram_user, status: "active", current_period_end: future)

    test_pid = self()

    stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    Session.handle_message(identity, "exam")
    assert_receive {:sent, _intro}, 1000
    assert_receive {:sent, _question}, 1000
    :sys.get_state({:via, Registry, {NursePrep.Whatsapp.SessionRegistry, identity}})

    telegram_session_id =
      NursePrep.Repo.get_by(WhatsappSession, phone: identity).state["quiz_session_id"]

    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    Quizzes.get_session!(telegram_session_id)
    |> Ecto.Changeset.change(expires_at: past)
    |> NursePrep.Repo.update!()

    assert :ok = perform_job(AutoSubmitExpiredExamWorker, %{})

    assert_receive {:sent, text}, 1000
    assert text =~ "Time's up"

    assert Quizzes.get_session!(telegram_session_id).status == "expired"
  end
end
