defmodule NursePrepWeb.WhatsappWebhookControllerTest do
  use NursePrepWeb.ConnCase, async: false

  import Mox
  import NursePrep.AccountsFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  # ConnectionAlert's alert-cooldown marker AND its live connected?/0 state
  # are process-global `:persistent_term`, not per-test-file — reset before
  # *and* after every test here. The `on_exit` half matters just as much:
  # skipping it after this file's "close" test would leak `connected?/0`
  # returning `false` into any other test file's `request_otp`/`user_fixture`
  # calls that happen to run next, not just NursePrep.Whatsapp.ConnectionAlertTest.
  setup do
    NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})

    on_exit(fn -> NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"}) end)

    :ok
  end

  # A fresh, unique phone per test (rather than one shared constant)-the
  # rate limiter `user_fixture/1` goes through (via `Accounts.request_otp/1`)
  # is ETS-backed, not part of the Ecto sandbox transaction, so its state
  # leaks across tests. Reusing one hardcoded number across every test in
  # this file tripped that per-phone limit after a handful of tests.
  #
  # Registered up front-the bot only replies to numbers that already
  # signed up (see the "unregistered number" test below for the other case).
  setup do
    phone = unique_user_phone()
    user_fixture(%{phone: phone})

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    %{phone: phone}
  end

  test "gives no reply at all to a number with no NursePrep account", %{conn: conn} do
    unregistered_phone = unique_user_phone()

    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "#{String.trim_leading(unregistered_phone, "+")}@s.whatsapp.net",
          "fromMe" => false,
          "id" => "MSG-UNREGISTERED-1"
        },
        "message" => %{"conversation" => "hi"}
      }
    }

    before_post = DateTime.utc_now()
    conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn, 200)

    # The webhook hands off to an async Task, so wait for the session
    # GenServer it spawns to actually process the cast before asserting on
    # the (lack of) side effects-there's no message to `assert_receive`
    # on when the whole point is that nothing gets sent. `last_interaction_at`
    # is set both at process init *and* at the top of every cast, so poll
    # until it's past `before_post` rather than just non-nil (a freshly
    # `init/1`'d process already has it set, before the cast even runs).
    wait_for_processed(unregistered_phone, before_post)

    refute NursePrep.Accounts.get_user_by_phone(unregistered_phone)
    refute NursePrep.Repo.get_by(NursePrep.Whatsapp.WhatsappSession, phone: unregistered_phone)

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, unregistered_phone) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)
  end

  defp wait_for_processed(phone, since, attempts \\ 50) do
    {:ok, pid} = NursePrep.Whatsapp.Session.start_or_lookup(phone)
    state = :sys.get_state(pid)

    if state.last_interaction_at && DateTime.compare(state.last_interaction_at, since) != :lt do
      :ok
    else
      Process.sleep(10)
      wait_for_processed(phone, since, attempts - 1)
    end
  end

  test "acks 200 immediately and routes a plain-text message to the session", %{
    conn: conn,
    phone: phone
  } do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
          "fromMe" => false,
          "id" => "MSG-PLAIN-TEXT-1"
        },
        "message" => %{"conversation" => "hi"}
      }
    }

    conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn, 200)

    assert_receive {:sent, text}, 1000
    assert text =~ "Here's everything I can do"
  end

  # Evolution API (confirmed against this app's own live instance) redelivers
  # a `messages.upsert` webhook event for the same WhatsApp message more than
  # once-the exact same "id" arrives twice. Undetected, that meant a
  # redelivered answer letter got submitted a second time, silently
  # advancing the quiz an extra question. `Mox.expect/3` defaults to
  # exactly one call, so a second real `send_text` from a duplicate slipping
  # through would fail this test on its own.
  test "processes a redelivered webhook event (same message id) only once", %{
    conn: conn,
    phone: phone
  } do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
          "fromMe" => false,
          "id" => "MSG-DUPLICATE-1"
        },
        "message" => %{"conversation" => "hi"}
      }
    }

    conn1 = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn1, 200)
    assert_receive {:sent, _text}, 1000

    conn2 = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn2, 200)
    refute_receive {:sent, _text}, 500
  end

  test "ignores messages sent by the bot itself (fromMe: true)", %{conn: conn, phone: phone} do
    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
          "fromMe" => true,
          "id" => "MSG-FROM-ME-1"
        },
        "message" => %{"conversation" => "echo of our own message"}
      }
    }

    conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn, 200)
    assert Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) == []
  end

  test "ignores group chat messages instead of crashing the session on a bad phone number", %{
    conn: conn
  } do
    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "2348031898040-1457518601@g.us",
          "fromMe" => false,
          "participant" => "2349050829790@s.whatsapp.net",
          "id" => "MSG-GROUP-1"
        },
        "message" => %{"conversation" => "Happy birthday sir"}
      }
    }

    conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn, 200)

    assert Registry.lookup(NursePrep.Whatsapp.SessionRegistry, "+2348031898040-1457518601") == []
  end

  # WhatsApp's newer privacy-ID address space-see the long comment on
  # `WhatsappWebhookController.extract_message/1`. Unlike a group JID, this
  # must NOT be dropped: it's routed through to the session (which then
  # runs its own one-time phone-confirmation flow, tested in
  # `NursePrep.Whatsapp.SessionTest`).
  test "routes an @lid message through to the session instead of dropping it like a group chat",
       %{conn: conn} do
    lid = "#{System.unique_integer([:positive, :monotonic])}@lid"
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _lid, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{"remoteJid" => lid, "fromMe" => false, "id" => "MSG-LID-1"},
        "message" => %{"conversation" => "hi"}
      }
    }

    conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload)
    assert response(conn, 200)

    assert_receive {:sent, text}, 1000
    assert text =~ "What's the phone number on your NursePrep account?"

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, lid) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
        [] -> :ok
      end
    end)
  end

  test "ignores non-message events without erroring", %{conn: conn} do
    conn =
      post(conn, ~p"/webhooks/evolution/no-token-configured", %{
        "event" => "connection.update",
        "data" => %{}
      })

    assert response(conn, 200)
  end

  # Evolution's healthcheck only proves the HTTP server is up, not that the
  # paired WhatsApp session is-see NursePrep.Whatsapp.ConnectionAlert's
  # moduledoc. These two cover the webhook's dispatch into that module.
  test "connection.update with state close triggers an alert", %{conn: conn} do
    NursePrep.Whatsapp.AlertSender.Test.clear()

    conn =
      post(conn, ~p"/webhooks/evolution/no-token-configured", %{
        "event" => "connection.update",
        "data" => %{"state" => "close", "statusReason" => 401}
      })

    assert response(conn, 200)
    assert wait_for_alert() == ["401"]
  end

  test "connection.update with state open does not alert", %{conn: conn} do
    NursePrep.Whatsapp.AlertSender.Test.clear()

    conn =
      post(conn, ~p"/webhooks/evolution/no-token-configured", %{
        "event" => "connection.update",
        "data" => %{"state" => "open"}
      })

    assert response(conn, 200)
    # No GenServer state to poll here (unlike wait_for_processed above), so
    # this gives the fire-and-forget Task a moment to have run if it were
    # (wrongly) going to alert, then asserts it didn't.
    Process.sleep(50)
    assert NursePrep.Whatsapp.AlertSender.Test.alerts() == []
  end

  defp wait_for_alert(attempts \\ 50) do
    case NursePrep.Whatsapp.AlertSender.Test.alerts() do
      [] when attempts > 0 ->
        Process.sleep(10)
        wait_for_alert(attempts - 1)

      alerts ->
        alerts
    end
  end

  # Evolution API replays chat history on link/reconnect, and some of those
  # payloads are large enough or oddly-encoded enough to arrive as invalid
  # JSON by the time they reach us. Must not 400/500-Evolution retry-storms
  # any non-2xx response (up to 10 attempts with backoff), so a single bad
  # payload could otherwise crowd out later, legitimate messages.
  test "malformed JSON body returns 200, not 400 or 500", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/evolution/no-token-configured", "{not valid json")

    assert response(conn, 200)
  end

  # Confirmed against evoapicloud/evolution-api v2.3.1 (the exact image this
  # app runs): Evolution appends a per-event suffix to the configured webhook
  # URL regardless of the `byEvents` instance setting, e.g.
  # `.../evolution/<token>//messages-upsert`. Must route to the same
  # controller as the bare `/evolution/:token` URL, not 404.
  test "event-suffixed URL still dispatches", %{conn: conn, phone: phone} do
    test_pid = self()

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
      send(test_pid, {:sent, text})
      {:ok, %{}}
    end)

    payload = %{
      "event" => "messages.upsert",
      "data" => %{
        "key" => %{
          "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
          "fromMe" => false,
          "id" => "MSG-SUFFIXED-1"
        },
        "message" => %{"conversation" => "hi"}
      }
    }

    conn = post(conn, "/webhooks/evolution/no-token-configured//messages-upsert", payload)
    assert response(conn, 200)
    assert_receive {:sent, _text}, 1000
  end

  # Per-phone floor independent of the message-id dedup covered above:
  # Evolution posts every event type (connection.update, presence.update,
  # message receipts, ...) to this one URL and can retry hard, so a
  # misbehaving or spammed number must not be able to flood `Session`
  # indefinitely.
  test "rate limit blocks excess messages from the same phone", %{conn: conn} do
    phone = unique_user_phone()
    user_fixture(%{phone: phone})

    stub(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, _text -> {:ok, %{}} end)

    payload = fn id ->
      %{
        "event" => "messages.upsert",
        "data" => %{
          "key" => %{
            "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
            "fromMe" => false,
            "id" => id
          },
          "message" => %{"conversation" => "hi"}
        }
      }
    end

    last_allowed_at = DateTime.utc_now()

    for i <- 1..20 do
      conn = post(conn, ~p"/webhooks/evolution/no-token-configured", payload.("MSG-RATE-#{i}"))
      assert response(conn, 200)
    end

    # Confirms message #20 (the last one within the limit) actually reached
    # the session before we check that #21 doesn't move it any further.
    wait_for_processed(phone, last_allowed_at)
    {:ok, pid} = NursePrep.Whatsapp.Session.start_or_lookup(phone)
    state_at_limit = :sys.get_state(pid)

    over_limit_conn =
      post(conn, ~p"/webhooks/evolution/no-token-configured", payload.("MSG-RATE-OVER-LIMIT"))

    assert response(over_limit_conn, 200)

    # The 21st message must never reach the session GenServer-give any
    # wrongly-admitted async Task time to land, then assert nothing changed.
    Process.sleep(100)
    state_after = :sys.get_state(pid)
    assert state_after.last_interaction_at == state_at_limit.last_interaction_at

    on_exit(fn ->
      case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
        [{p, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, p)
        [] -> :ok
      end
    end)
  end

  describe "with a webhook token configured" do
    setup do
      original = Application.get_env(:nurseprep, :evolution_api)

      Application.put_env(
        :nurseprep,
        :evolution_api,
        Keyword.put(original, :webhook_token, "secret")
      )

      on_exit(fn -> Application.put_env(:nurseprep, :evolution_api, original) end)
    end

    test "rejects a wrong token in the URL path", %{conn: conn} do
      conn =
        post(conn, ~p"/webhooks/evolution/wrong-token", %{
          "event" => "messages.upsert",
          "data" => %{}
        })

      assert response(conn, 401)
    end

    test "accepts the matching token in the URL path", %{conn: conn, phone: phone} do
      test_pid = self()

      expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      payload = %{
        "event" => "messages.upsert",
        "data" => %{
          "key" => %{
            "remoteJid" => "#{String.trim_leading(phone, "+")}@s.whatsapp.net",
            "fromMe" => false,
            "id" => "MSG-TOKEN-1"
          },
          "message" => %{"conversation" => "hi"}
        }
      }

      conn = post(conn, ~p"/webhooks/evolution/secret", payload)
      assert response(conn, 200)
      assert_receive {:sent, _text}, 1000
    end
  end
end
