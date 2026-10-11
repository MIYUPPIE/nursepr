defmodule NursePrep.Whatsapp.AlertSender.Test do
  @moduledoc """
  Test `AlertSender` implementation: stashes every alert reason delivered in
  a public ETS table instead of actually sending anything, so tests can
  assert on it regardless of which process (the webhook's `Task`) triggered
  delivery. Mirrors `NursePrep.Accounts.EmailOtpSender.Test`.
  """
  @behaviour NursePrep.Whatsapp.AlertSender

  @table :whatsapp_alert_sender_test_reasons

  @impl true
  def deliver(reason) do
    :ets.insert(@table, {System.unique_integer([:monotonic]), reason})
    :ok
  end

  def alerts,
    do: @table |> :ets.tab2list() |> Enum.sort() |> Enum.map(fn {_seq, reason} -> reason end)

  def clear, do: :ets.delete_all_objects(@table)
end
