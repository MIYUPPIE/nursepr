defmodule NursePrep.Accounts.PhoneNumber do
  @moduledoc """
  Normalizes phone numbers to E.164 so `users.phone`, Evolution API's
  `remoteJid`, and Paystack customer records all key off the exact same
  string. Defaults to the Nigerian region since that's the target market,
  but accepts any number already in international `+` format.
  """

  @default_region "NG"

  @doc """
  Normalizes a phone number to E.164 (e.g. "+2348012345678").

  Accepts local Nigerian formats (`08012345678`, `8012345678`) as well as
  already-international numbers (`+2348012345678`).
  """
  def normalize(phone) when is_binary(phone) do
    case ExPhoneNumber.parse(phone, @default_region) do
      {:ok, parsed} ->
        if ExPhoneNumber.is_valid_number?(parsed) do
          {:ok, ExPhoneNumber.Formatting.format(parsed, :e164)}
        else
          {:error, "is not a valid phone number"}
        end

      {:error, _reason} ->
        {:error, "is not a valid phone number"}
    end
  end
end
