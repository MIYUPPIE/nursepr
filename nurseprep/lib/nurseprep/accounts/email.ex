defmodule NursePrep.Accounts.Email do
  @moduledoc """
  Normalizes email addresses for the students who don't have WhatsApp:
  trims and downcases so `Foo@Example.com` and `foo@example.com ` collide
  on the same account, and checks just enough shape to catch a typo before
  an OTP gets "sent" to a dead address.
  """

  @format ~r/^[^\s]+@[^\s]+\.[^\s]+$/

  @doc """
  Normalizes an email address, returning `{:ok, normalized}` or
  `{:error, reason}`.
  """
  def normalize(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if Regex.match?(@format, normalized) do
      {:ok, normalized}
    else
      {:error, "is not a valid email address"}
    end
  end
end
