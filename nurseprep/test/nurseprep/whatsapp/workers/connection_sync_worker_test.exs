defmodule NursePrep.Whatsapp.Workers.ConnectionSyncWorkerTest do
  # ConnectionAlert reads/writes :persistent_term (process-global VM
  # state), same reason ConnectionAlertTest itself runs sync.
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import Mox

  alias NursePrep.Whatsapp.ConnectionAlert
  alias NursePrep.Whatsapp.Workers.ConnectionSyncWorker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConnectionAlert.handle_state_update(%{"state" => "open"})
    on_exit(fn -> ConnectionAlert.handle_state_update(%{"state" => "open"}) end)
    :ok
  end

  test "flips connected?/0 to false when Evolution reports the session closed" do
    expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn -> {:ok, "close"} end)

    assert ConnectionAlert.connected?()
    assert :ok = perform_job(ConnectionSyncWorker, %{})
    refute ConnectionAlert.connected?()
  end

  test "leaves connected?/0 true when Evolution confirms the session is open" do
    expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn -> {:ok, "open"} end)

    assert :ok = perform_job(ConnectionSyncWorker, %{})
    assert ConnectionAlert.connected?()
  end

  # The regression case this worker exists for: a webhook was missed while
  # WhatsApp was down, so `connected?/0` is stuck reporting `true` with no
  # deploy in sight to trigger the boot-time sync. The next cron tick must
  # still self-heal it.
  test "self-heals a stale true reading with no deploy involved" do
    expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn -> {:ok, "close"} end)

    assert ConnectionAlert.connected?()
    assert :ok = perform_job(ConnectionSyncWorker, %{})
    refute ConnectionAlert.connected?()
  end

  test "leaves the existing state in place when Evolution is unreachable or unconfigured" do
    expect(NursePrep.Whatsapp.EvolutionClientMock, :connection_state, fn ->
      {:error, :not_configured}
    end)

    assert ConnectionAlert.connected?()
    assert :ok = perform_job(ConnectionSyncWorker, %{})
    assert ConnectionAlert.connected?()
  end
end
