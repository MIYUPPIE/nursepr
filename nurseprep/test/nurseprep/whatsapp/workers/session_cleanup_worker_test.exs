defmodule NursePrep.Whatsapp.Workers.SessionCleanupWorkerTest do
  use NursePrep.DataCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  import NursePrep.AccountsFixtures
  import Mox

  alias NursePrep.Repo
  alias NursePrep.Whatsapp.{Session, WhatsappSession}
  alias NursePrep.Whatsapp.Workers.SessionCleanupWorker

  setup :set_mox_global
  setup :verify_on_exit!

  test "deletes expired whatsapp_sessions rows and leaves fresh ones alone" do
    expired_phone = unique_user_phone()
    fresh_phone = unique_user_phone()
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

    %WhatsappSession{}
    |> WhatsappSession.changeset(%{"phone" => expired_phone, "state" => %{}, "expires_at" => past})
    |> Repo.insert!()

    %WhatsappSession{}
    |> WhatsappSession.changeset(%{"phone" => fresh_phone, "state" => %{}, "expires_at" => future})
    |> Repo.insert!()

    assert :ok = perform_job(SessionCleanupWorker, %{})

    refute Repo.get_by(WhatsappSession, phone: expired_phone)
    assert Repo.get_by(WhatsappSession, phone: fresh_phone)
  end

  test "terminates a live GenServer whose row has expired" do
    phone = unique_user_phone()
    user_fixture(%{phone: phone})
    on_exit(fn -> terminate_session(phone) end)

    expect(NursePrep.Whatsapp.EvolutionClientMock, :send_text, fn _phone, _text -> {:ok, %{}} end)
    Session.handle_message(phone, "hi")
    :sys.get_state({:via, Registry, {NursePrep.Whatsapp.SessionRegistry, phone}})

    {:ok, pid} = Session.start_or_lookup(phone)
    assert Process.alive?(pid)

    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    Repo.get_by!(WhatsappSession, phone: phone)
    |> Ecto.Changeset.change(expires_at: past)
    |> Repo.update!()

    assert :ok = perform_job(SessionCleanupWorker, %{})

    refute Process.alive?(pid)
  end

  defp terminate_session(phone) do
    case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(NursePrep.Whatsapp.SessionSupervisor, pid)
      [] -> :ok
    end
  end
end
