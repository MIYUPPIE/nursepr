defmodule NursePrep.Subscriptions.Workers.PaystackEventWorker do
  @moduledoc """
  Processes one Paystack webhook event out-of-band from the webhook
  request itself, so a slow DB write never risks Paystack's webhook
  timeout (and its resulting retries).
  """
  use Oban.Worker, queue: :payments, max_attempts: 5

  alias NursePrep.Subscriptions

  def enqueue(event_type, data) do
    %{"event_type" => event_type, "data" => data}
    |> new()
    |> Oban.insert()
  end

  @impl true
  def perform(%Oban.Job{args: %{"event_type" => event_type, "data" => data}}) do
    case Subscriptions.handle_paystack_event(event_type, data) do
      {:error, :payment_not_found} -> :ok
      _ -> :ok
    end
  end
end
