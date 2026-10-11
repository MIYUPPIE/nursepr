defmodule NursePrep.Whatsapp.ConnectionAlertTest do
  # :persistent_term is process-global VM state (the cooldown marker), so
  # this file can't run concurrently with itself.
  use ExUnit.Case, async: false

  import Mox

  alias NursePrep.Whatsapp.AlertSender
  alias NursePrep.Whatsapp.ConnectionAlert

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Reset the cooldown marker via the module's own "open" clause (safe
    # no-op if nothing was ever set) rather than poking :persistent_term
    # directly, so this test doesn't depend on ConnectionAlert's private key.
    ConnectionAlert.handle_state_update(%{"state" => "open"})
    AlertSender.Test.clear()

    # The `on_exit` reset matters as much as the `setup` one:
    # `:persistent_term` is process-global VM state, not sandboxed per
    # test, so a "close" test here that skipped resetting back to "open"
    # would leak `connected?/0` returning `false` into *any* other test
    # file's `request_otp`/`user_fixture` calls that happen to run next.
    on_exit(fn -> ConnectionAlert.handle_state_update(%{"state" => "open"}) end)

    :ok
  end

  test "state close sends exactly one alert with the disconnect reason" do
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
    assert AlertSender.Test.alerts() == ["401"]
  end

  test "a second close within the cooldown window does not alert again" do
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
    assert AlertSender.Test.alerts() == ["401"]
  end

  test "state open clears the cooldown so the next close alerts immediately" do
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "open"})
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 515})

    assert AlertSender.Test.alerts() == ["401", "515"]
  end

  test "state open with no prior outage is a no-op" do
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "open"})
    assert AlertSender.Test.alerts() == []
  end

  test "falls back to the reason key, then \"unknown\", when statusReason is absent" do
    assert :ok =
             ConnectionAlert.handle_state_update(%{"state" => "close", "reason" => "logged_out"})

    assert AlertSender.Test.alerts() == ["logged_out"]

    ConnectionAlert.handle_state_update(%{"state" => "open"})
    AlertSender.Test.clear()

    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "close"})
    assert AlertSender.Test.alerts() == ["unknown"]
  end

  test "an intermediate state like \"connecting\" does not alert" do
    assert :ok = ConnectionAlert.handle_state_update(%{"state" => "connecting"})
    assert AlertSender.Test.alerts() == []
  end

  test "a payload with no state at all does not crash and does not alert" do
    assert :ok = ConnectionAlert.handle_state_update(%{})
    assert AlertSender.Test.alerts() == []
  end

  describe "connected?/0" do
    test "reads true when no close event is in effect" do
      assert ConnectionAlert.connected?()
    end

    test "flips to false on a close event" do
      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
      refute ConnectionAlert.connected?()
    end

    test "flips back to true on an open event" do
      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
      ConnectionAlert.handle_state_update(%{"state" => "open"})
      assert ConnectionAlert.connected?()
    end

    # Proves live connection state isn't accidentally gated by the alert
    # cooldown-a second close within the cooldown window still suppresses
    # a duplicate *email*, but must not report "connected" in the meantime.
    test "a second close inside the alert cooldown still reports disconnected" do
      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
      ConnectionAlert.handle_state_update(%{"state" => "open"})
      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})
      ConnectionAlert.handle_state_update(%{"state" => "close", "statusReason" => 401})

      refute ConnectionAlert.connected?()
    end

    test "an intermediate state like \"connecting\" does not change connected?/0" do
      assert ConnectionAlert.connected?()
      ConnectionAlert.handle_state_update(%{"state" => "connecting"})
      assert ConnectionAlert.connected?()
    end
  end

  describe "sync_from_evolution/0" do
    # Regression coverage for a real production incident (2026-08-15): a
    # deploy landed while WhatsApp was already mid-outage. `connected?/0`'s
    # "assume connected" boot default came back `true` with no new
    # `connection.update` webhook incoming to correct it (WhatsApp's state
    # wasn't *changing*, just staying down), so every OTP silently kept
    # trying-and failing-a WhatsApp send instead of falling back to
    # Telegram. This proves a boot-time sync closes that gap.
    test "flips connected?/0 to false when Evolution reports the session is actually closed" do
      expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn ->
        {:ok, "close"}
      end)

      assert ConnectionAlert.connected?()
      assert :ok = ConnectionAlert.sync_from_evolution()
      refute ConnectionAlert.connected?()
    end

    test "leaves connected?/0 true when Evolution confirms the session is open" do
      expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn -> {:ok, "open"} end)

      assert :ok = ConnectionAlert.sync_from_evolution()
      assert ConnectionAlert.connected?()
    end

    test "leaves the existing default in place when Evolution is unreachable or unconfigured" do
      expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn ->
        {:error, :not_configured}
      end)

      assert :ok = ConnectionAlert.sync_from_evolution()
      assert ConnectionAlert.connected?()
    end
  end
end
