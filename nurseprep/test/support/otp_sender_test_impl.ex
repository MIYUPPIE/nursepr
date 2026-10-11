defmodule NursePrep.Accounts.OtpSender.Test do
  @moduledoc """
  Test `OtpSender` implementation: stashes the last code sent per phone
  number in a public ETS table instead of actually sending anything, so
  fixtures/tests can retrieve the real code regardless of which process
  triggered delivery (a LiveView process, not necessarily the test process
  itself). Keyed by phone so concurrent `async: true` tests-each using a
  unique fixture phone number-never see each other's codes.
  """
  @behaviour NursePrep.Accounts.OtpSender

  @table :otp_sender_test_codes

  # Reserved sentinel outside `AccountsFixtures.unique_user_phone/0`'s
  # `+234803...` range, so it can never collide with a fixture-generated
  # number-simulates a real delivery failure (Evolution API down, WhatsApp
  # instance disconnected) for testing that failures propagate instead of
  # being swallowed.
  @failing_phone "+2348160000000"

  def failing_phone, do: @failing_phone

  @impl true
  def deliver(@failing_phone, _code), do: {:error, :simulated_failure}

  def deliver(phone, code) do
    :ets.insert(@table, {phone, code})
    :ok
  end

  def last_code(phone) do
    case :ets.lookup(@table, phone) do
      [{^phone, code}] -> code
      [] -> nil
    end
  end
end
