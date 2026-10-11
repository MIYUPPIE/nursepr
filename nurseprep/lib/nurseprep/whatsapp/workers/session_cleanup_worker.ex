defmodule NursePrep.Whatsapp.Workers.SessionCleanupWorker do
  @moduledoc """
  Hourly sweep for abandoned WhatsApp conversations. `Session.init/1`
  already lazily drops a row past its hard expiry the next time that
  phone number messages in-but a number that never messages again
  would otherwise linger in `whatsapp_sessions` forever, and if its
  GenServer is still alive (soft-timeout hibernation, no restart since),
  it would sit in memory past its stated expiry with no inbound message
  ever coming along to trigger the reactive cleanup. This worker makes
  the expiry a real deadline instead of one that only fires reactively.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  import Ecto.Query

  alias NursePrep.Repo
  alias NursePrep.Whatsapp.{WhatsappSession, SessionRegistry, SessionSupervisor}

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired_phones =
      WhatsappSession
      |> where([s], s.expires_at < ^now)
      |> select([s], s.phone)
      |> Repo.all()

    Enum.each(expired_phones, &terminate_if_alive/1)

    {count, _} =
      Repo.delete_all(from s in WhatsappSession, where: s.expires_at < ^now)

    :telemetry.execute([:nurseprep, :whatsapp, :session_cleanup], %{expired_count: count}, %{})

    :ok
  end

  defp terminate_if_alive(phone) do
    case Registry.lookup(SessionRegistry, phone) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      [] -> :ok
    end
  end
end
