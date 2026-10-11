defmodule NursePrep.Accounts.EmailOtpSender.Test do
  @moduledoc """
  Test `EmailOtpSender` implementation: stashes the last code sent per
  email address in a public ETS table instead of actually sending
  anything, so fixtures/tests can retrieve the real code regardless of
  which process triggered delivery. Keyed by email so concurrent
  `async: true` tests-each using a unique fixture email-never see each
  other's codes. Mirrors `NursePrep.Accounts.OtpSender.Test`.
  """
  @behaviour NursePrep.Accounts.EmailOtpSender

  @table :email_otp_sender_test_codes

  @impl true
  def deliver(email, code) do
    :ets.insert(@table, {email, code})
    :ok
  end

  def last_code(email) do
    case :ets.lookup(@table, email) do
      [{^email, code}] -> code
      [] -> nil
    end
  end
end
