defmodule NursePrep.Accounts.OtpSender do
  @moduledoc """
  Delivers OTP login codes out-of-band. `OtpSender.Log` is used in dev/test
  so login works before any WhatsApp credentials exist; `OtpSender.Evolution`
  (added in the WhatsApp milestone) sends the real message. Swap the
  implementation via `config :nurseprep, :otp_sender, ...`-nothing else in
  the auth flow needs to change.
  """

  @callback deliver(phone :: String.t(), code :: String.t()) :: :ok | {:error, term()}

  def deliver(phone, code), do: impl().deliver(phone, code)

  defp impl, do: Application.get_env(:nurseprep, :otp_sender, NursePrep.Accounts.OtpSender.Log)
end

defmodule NursePrep.Accounts.OtpSender.Log do
  @moduledoc "Logs the OTP code instead of sending it. Dev/test default."
  @behaviour NursePrep.Accounts.OtpSender

  require Logger

  @impl true
  def deliver(phone, code) do
    Logger.info("[OTP] login code for #{phone}: #{code}")
    :ok
  end
end

defmodule NursePrep.Accounts.OtpSender.Evolution do
  @moduledoc "Delivers the OTP code as a WhatsApp text message via Evolution API."
  @behaviour NursePrep.Accounts.OtpSender

  @impl true
  def deliver(phone, code) do
    client =
      Application.get_env(:nurseprep, :evolution_client, NursePrep.Whatsapp.EvolutionClient)

    case client.send_text(
           phone,
           "Your NursePrep login code is #{code}. It expires in 10 minutes."
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule NursePrep.Accounts.OtpSender.Telegram do
  @moduledoc """
  Delivers the OTP code as a Telegram text message-the WhatsApp-down
  fallback `Accounts.request_otp/1` uses for a student who already linked
  Telegram (see `Whatsapp.Session.route_telegram_confirmation/2`). Unlike
  `.Evolution`/`.Log`, not swapped in via `config :nurseprep, :otp_sender`:
  there's no dev/prod variant to choose between, `Accounts` calls this
  module directly only when it's decided Telegram is the right channel for
  this particular request.
  """
  @behaviour NursePrep.Accounts.OtpSender

  @impl true
  def deliver(identity, code) do
    case NursePrep.Messaging.send_text(
           identity,
           "Your NursePrep login code is #{code}. It expires in 10 minutes."
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
