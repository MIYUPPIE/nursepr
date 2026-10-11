defmodule NursePrepWeb.TelegramWebhookControllerTest do
  use NursePrepWeb.ConnCase, async: false

  import Mox
  import NursePrep.AccountsFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  # A fresh, unique chat id per test-mirrors the WhatsApp webhook test's
  # per-phone rate limiter isolation reasoning (Hammer is ETS-backed, not
  # part of the Ecto sandbox transaction, so state leaks across tests that
  # share one identity).
  setup do
    chat_id = System.unique_integer([:positive, :monotonic])
    %{phone: phone} = user_fixture()
    NursePrep.Accounts.link_telegram_chat_id(NursePrep.Accounts.get_user_by_phone(phone), chat_id)

    identity = NursePrep.Messaging.tag_telegram(chat_id)

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, identity) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    %{chat_id: chat_id, identity: identity}
  end

  defp payload(chat_id, text, opts \\ []) do
    %{
      "update_id" => Keyword.get(opts, :update_id, System.unique_integer([:positive])),
      "message" => %{
        "chat" => %{"id" => chat_id, "type" => Keyword.get(opts, :chat_type, "private")},
        "text" => text
      }
    }
  end

  test "acks 200 immediately and routes a plain-text message to the session", %{
    conn: conn,
    chat_id: chat_id
  } do
    test_pid = self()

    expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    conn = post(conn, ~p"/webhooks/telegram", payload(chat_id, "hi"))
    assert response(conn, 200)

    assert_receive {:sent, text}, 1000
    assert text =~ "Here's everything I can do"
  end

  test "processes a redelivered update (same update_id) only once", %{
    conn: conn,
    chat_id: chat_id
  } do
    test_pid = self()

    expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    update = payload(chat_id, "hi", update_id: 42)

    conn1 = post(conn, ~p"/webhooks/telegram", update)
    assert response(conn1, 200)
    assert_receive {:sent, _text}, 1000

    conn2 = post(conn, ~p"/webhooks/telegram", update)
    assert response(conn2, 200)
    refute_receive {:sent, _text}, 500
  end

  test "ignores group/supergroup/channel chats instead of replying", %{
    conn: conn,
    chat_id: chat_id
  } do
    for chat_type <- ["group", "supergroup", "channel"] do
      conn = post(conn, ~p"/webhooks/telegram", payload(chat_id, "hi", chat_type: chat_type))
      assert response(conn, 200)
    end

    assert Registry.lookup(NursePrep.Whatsapp.SessionRegistry, "telegram:#{chat_id}") == []
  end

  test "ignores non-text messages (photos, stickers, etc.)", %{conn: conn, chat_id: chat_id} do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "chat" => %{"id" => chat_id, "type" => "private"},
        "photo" => [%{"file_id" => "abc"}]
      }
    }

    conn = post(conn, ~p"/webhooks/telegram", update)
    assert response(conn, 200)

    assert Registry.lookup(NursePrep.Whatsapp.SessionRegistry, "telegram:#{chat_id}") == []
  end

  test "ignores non-message updates (e.g. edited_message) without erroring", %{conn: conn} do
    conn = post(conn, ~p"/webhooks/telegram", %{"update_id" => 1, "edited_message" => %{}})
    assert response(conn, 200)
  end

  test "rate limit blocks excess messages from the same chat", %{conn: conn, chat_id: chat_id} do
    stub(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, _text -> {:ok, %{}} end)

    last_allowed_at = DateTime.utc_now()

    for _ <- 1..20 do
      conn = post(conn, ~p"/webhooks/telegram", payload(chat_id, "hi"))
      assert response(conn, 200)
    end

    identity = "telegram:#{chat_id}"
    wait_for_processed(identity, last_allowed_at)
    {:ok, pid} = NursePrep.Whatsapp.Session.start_or_lookup(identity)
    state_at_limit = :sys.get_state(pid)

    over_limit_conn = post(conn, ~p"/webhooks/telegram", payload(chat_id, "hi"))
    assert response(over_limit_conn, 200)

    Process.sleep(100)
    state_after = :sys.get_state(pid)
    assert state_after.last_interaction_at == state_at_limit.last_interaction_at
  end

  defp wait_for_processed(identity, since, attempts \\ 50) do
    {:ok, pid} = NursePrep.Whatsapp.Session.start_or_lookup(identity)
    state = :sys.get_state(pid)

    if state.last_interaction_at && DateTime.compare(state.last_interaction_at, since) != :lt do
      :ok
    else
      Process.sleep(10)
      wait_for_processed(identity, since, attempts - 1)
    end
  end

  describe "with a webhook secret configured" do
    setup do
      original = Application.get_env(:nurseprep, :telegram_api)

      Application.put_env(
        :nurseprep,
        :telegram_api,
        Keyword.put(original || [], :webhook_secret, "secret")
      )

      on_exit(fn -> Application.put_env(:nurseprep, :telegram_api, original) end)
    end

    test "rejects a missing or wrong secret-token header", %{conn: conn, chat_id: chat_id} do
      conn = post(conn, ~p"/webhooks/telegram", payload(chat_id, "hi"))
      assert response(conn, 401)

      conn =
        build_conn()
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong")
        |> post(~p"/webhooks/telegram", payload(chat_id, "hi"))

      assert response(conn, 401)
    end

    test "accepts the matching secret-token header", %{conn: conn, chat_id: chat_id} do
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn ^chat_id, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", "secret")
        |> post(~p"/webhooks/telegram", payload(chat_id, "hi"))

      assert response(conn, 200)
      assert_receive {:sent, _text}, 1000
    end
  end
end
