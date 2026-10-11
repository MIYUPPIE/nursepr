defmodule NursePrep.Whatsapp.Workers.ConnectionSyncWorker do
  @moduledoc """
  Periodically reconciles `ConnectionAlert.connected?/0` against Evolution's
  actual connection state-the ongoing counterpart to the one-shot boot sync
  in `NursePrep.Application`.

  `ConnectionAlert.handle_state_update/1` (fed by Evolution's
  `connection.update` webhook) is otherwise the *only* thing that can flip
  `connected?/0`. That's a single point of failure: if a webhook delivery
  is ever missed (network blip between Evolution and this app, Evolution
  itself hiccuping, an unexpected payload shape) while WhatsApp is down,
  nothing else corrects the "connected" flag-it sits stuck `true` for the
  life of the running node, `request_otp/1` keeps attempting (and losing)
  a WhatsApp send, and the Telegram fallback never triggers for students
  who already linked it. The boot-time sync in `NursePrep.Application`
  only helps if a deploy happens to land during the outage; an outage that
  starts and continues between deploys, with a swallowed webhook, isn't
  covered by anything else in the codebase. This worker is that coverage.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  alias NursePrep.Whatsapp.ConnectionAlert

  @impl Oban.Worker
  def perform(_job), do: ConnectionAlert.sync_from_evolution()
end
