defmodule NursePrep.Accounts.EmailOtpSender do
  @moduledoc """
  Delivers OTP login codes to students who don't have WhatsApp, over email
  instead. Mirrors `NursePrep.Accounts.OtpSender`: `.Log` is used in
  dev/test so email login works before any SMTP credentials exist;
  `.Mailer` sends the real email once they do. Swap the implementation via
  `config :nurseprep, :email_otp_sender, ...`-nothing else in the auth
  flow needs to change.
  """

  @callback deliver(email :: String.t(), code :: String.t()) :: :ok | {:error, term()}

  def deliver(email, code), do: impl().deliver(email, code)

  defp impl,
    do: Application.get_env(:nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Log)
end

defmodule NursePrep.Accounts.EmailOtpSender.Log do
  @moduledoc "Logs the OTP code instead of emailing it. Dev/test default."
  @behaviour NursePrep.Accounts.EmailOtpSender

  require Logger

  @impl true
  def deliver(email, code) do
    Logger.info("[OTP] login code for #{email}: #{code}")
    :ok
  end
end

defmodule NursePrep.Accounts.EmailOtpSender.Mailer do
  @moduledoc "Delivers the OTP code as a real email via Swoosh."
  @behaviour NursePrep.Accounts.EmailOtpSender

  import Swoosh.Email
  alias NursePrep.Mailer

  @impl true
  def deliver(email, code) do
    email
    |> build_email(code)
    |> Mailer.deliver()
    |> case do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_email(to, code) do
    from_email = Application.get_env(:nurseprep, :mailer_from_email, "no-reply@nurseprep.ng")

    new()
    |> to(to)
    |> from({"NursePrep", from_email})
    |> subject("Your NursePrep login code")
    |> text_body("Your NursePrep login code is #{code}. It expires in 10 minutes.")
    |> html_body("""
    <p>Your NursePrep login code is <strong>#{code}</strong>.</p>
    <p>It expires in 10 minutes. If you didn't request this, you can safely ignore this email.</p>
    """)
  end
end
