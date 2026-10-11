defmodule NursePrep.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NursePrepWeb.Telemetry,
      NursePrep.Repo,
      {DNSCluster, query: Application.get_env(:nurseprep, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NursePrep.PubSub},
      {Oban, Application.fetch_env!(:nurseprep, Oban)},
      {Task.Supervisor, name: NursePrep.TaskSupervisor},
      {Registry, keys: :unique, name: NursePrep.Whatsapp.SessionRegistry},
      {DynamicSupervisor, name: NursePrep.Whatsapp.SessionSupervisor, strategy: :one_for_one},
      # Named Finch pools per external service so a slow/misbehaving one
      # (e.g. xAI under load) can't starve requests to the others.
      {Finch, name: NursePrep.Finch.Evolution},
      {Finch, name: NursePrep.Finch.Paystack},
      {Finch, name: NursePrep.Finch.Xai},
      {Finch, name: NursePrep.Finch.Telegram},
      # Start to serve requests, typically the last entry
      NursePrepWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NursePrep.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Fire-and-forget: corrects ConnectionAlert's "assume WhatsApp is
      # connected" boot default against Evolution's real state, so a
      # deploy landing mid-outage doesn't get stuck routing OTPs/quiz
      # drops at a WhatsApp send that's already known to fail instead of
      # the Telegram fallback (see ConnectionAlert's moduledoc). Async and
      # best-effort so a slow/unreachable Evolution API never delays boot.
      # Skipped under test: Mix starts this OTP app before requiring
      # test_helper.exs, which is where EvolutionClientMock gets defined,
      # so calling through it here would race a not-yet-existing module.
      if Application.get_env(:nurseprep, :env) != :test do
        Task.Supervisor.start_child(NursePrep.TaskSupervisor, fn ->
          NursePrep.Whatsapp.ConnectionAlert.sync_from_evolution()
        end)
      end

      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NursePrepWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
