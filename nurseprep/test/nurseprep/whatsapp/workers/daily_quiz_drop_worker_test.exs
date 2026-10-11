defmodule NursePrep.Whatsapp.Workers.DailyQuizDropWorkerTest do
  # async: false-tests here flip NursePrep.Whatsapp.ConnectionAlert's
  # process-global :persistent_term connection state, which isn't safe to
  # race against other test files doing the same.
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import NursePrep.Factory
  import NursePrep.AccountsFixtures
  import Mox

  alias NursePrep.Accounts
  alias NursePrep.Messaging
  alias NursePrep.Whatsapp.ConnectionAlert
  alias NursePrep.Whatsapp.Workers.DailyQuizDropWorker

  setup :set_mox_global
  setup :verify_on_exit!

  # Every WhatsApp-connection test in the suite resets this the same way
  # (see ConnectionAlertTest) — keeps this file's default state predictable
  # regardless of what ran before it. The `on_exit` reset matters just as
  # much as the `setup` one: `:persistent_term` is process-global VM state,
  # not sandboxed per test, so a "close" test that skipped resetting back
  # to "open" would leak into *any* other test file's `request_otp`/
  # `user_fixture` calls that happen to run afterward — not just this one.
  setup do
    ConnectionAlert.handle_state_update(%{"state" => "open"})
    on_exit(fn -> ConnectionAlert.handle_state_update(%{"state" => "open"}) end)
    :ok
  end

  defp terminate_session(identity) do
    case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
      [] -> :ok
    end
  end

  describe "fan-out (empty args, cron-triggered)" do
    test "enqueues one unique job per opt-in user, skipping opted-out ones" do
      opted_in = user_fixture()
      insert(:profile_for, user: opted_in, whatsapp_opt_in: true)

      opted_out = user_fixture()
      insert(:profile_for, user: opted_out, whatsapp_opt_in: false)

      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert_enqueued(
        worker: DailyQuizDropWorker,
        args: %{"user_id" => opted_in.id, "identity" => opted_in.phone}
      )

      refute_enqueued(worker: DailyQuizDropWorker, args: %{"user_id" => opted_out.id})
    end

    test "does not double-enqueue the same user across two fan-out runs" do
      user = user_fixture()
      insert(:profile_for, user: user, whatsapp_opt_in: true)

      assert :ok = perform_job(DailyQuizDropWorker, %{})
      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert length(all_enqueued(worker: DailyQuizDropWorker, args: %{"user_id" => user.id})) == 1
    end

    test "includes a phone-less, Telegram-linked user, tagged with their Telegram identity" do
      user = email_user_fixture()
      {:ok, user} = Accounts.link_telegram_chat_id(user, 987_654_321)
      insert(:profile_for, user: user, whatsapp_opt_in: true)

      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert_enqueued(
        worker: DailyQuizDropWorker,
        args: %{"user_id" => user.id, "identity" => Messaging.tag_telegram(987_654_321)}
      )
    end
  end

  describe "per-user send" do
    test "sends a one-question quiz over WhatsApp and puts the session into an answer-awaiting state" do
      user = user_fixture()
      insert(:profile_for, user: user, whatsapp_opt_in: true)
      insert_question_with_options()
      on_exit(fn -> terminate_session(user.phone) end)

      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, 2, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      assert :ok =
               perform_job(DailyQuizDropWorker, %{"user_id" => user.id, "identity" => user.phone})

      :sys.get_state({:via, Registry, {NursePrep.Whatsapp.SessionRegistry, user.phone}})

      assert_received {:sent, "🔔 Here's your daily practice question:"}
      assert_received {:sent, "*Question 1/1*" <> _}
    end

    test "prefers WhatsApp over a linked Telegram id when WhatsApp is connected" do
      user = user_fixture()
      {:ok, user} = Accounts.link_telegram_chat_id(user, 111_111_111)
      insert(:profile_for, user: user, whatsapp_opt_in: true)

      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert_enqueued(
        worker: DailyQuizDropWorker,
        args: %{"user_id" => user.id, "identity" => user.phone}
      )
    end

    test "falls back to Telegram when WhatsApp is disconnected and this user has linked one" do
      user = user_fixture()
      {:ok, user} = Accounts.link_telegram_chat_id(user, 222_222_222)
      insert(:profile_for, user: user, whatsapp_opt_in: true)

      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})

      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert_enqueued(
        worker: DailyQuizDropWorker,
        args: %{"user_id" => user.id, "identity" => Messaging.tag_telegram(222_222_222)}
      )
    end

    test "falls back to (a doomed) phone attempt when WhatsApp is disconnected and no Telegram is linked-matches pre-Telegram behavior rather than silently skipping" do
      user = user_fixture()
      insert(:profile_for, user: user, whatsapp_opt_in: true)

      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})

      assert :ok = perform_job(DailyQuizDropWorker, %{})

      assert_enqueued(
        worker: DailyQuizDropWorker,
        args: %{"user_id" => user.id, "identity" => user.phone}
      )
    end
  end
end
