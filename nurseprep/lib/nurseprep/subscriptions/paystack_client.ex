defmodule NursePrep.Subscriptions.PaystackClient do
  @moduledoc """
  Thin `Req`-based wrapper around the two Paystack endpoints this app
  actually needs. Deliberately hand-rolled rather than a hex dependency —
  the surface is tiny (initialize + verify) and this is security/money
  code, worth owning outright rather than trusting a thin community
  wrapper's maintenance.

  Paystack's customer model requires an email address. Users who signed up
  with email already have a real one; phone-only (WhatsApp) users don't, so
  `synthetic_email/1` derives a stable, deterministic placeholder from the
  phone number instead-Paystack uses it only as a customer-record key for
  card payments in Nigeria, never as a real delivery channel, so this is a
  safe fallback rather than requiring a real email address up front just to
  satisfy this one integration.
  """

  @base_url "https://api.paystack.co"

  def initialize_transaction(user, amount_kobo, reference) do
    request(:post, "/transaction/initialize",
      json: %{
        "email" => user.email || synthetic_email(user.phone),
        "amount" => amount_kobo,
        "reference" => reference,
        "callback_url" => callback_url()
      }
    )
  end

  def verify_transaction(reference) do
    request(:get, "/transaction/verify/#{reference}")
  end

  defp synthetic_email(phone) do
    digits = String.replace(phone, "+", "")
    "#{digits}@users.nurseprep.ng"
  end

  # Where Paystack sends the browser back after checkout. The webhook is
  # the durable source of truth for entitlement, but relying on it alone
  # would leave a user staring at Paystack's own default "return to
  # merchant" page with no way back into the app-this callback route
  # (see `NursePrepWeb.SubscriptionCallbackController`) verifies the
  # transaction synchronously and redirects straight back to /subscription.
  defp callback_url, do: NursePrepWeb.Endpoint.url() <> "/subscription/callback"

  defp request(method, path, opts \\ []) do
    config = Application.fetch_env!(:nurseprep, :paystack)

    cond do
      config[:plug] ->
        do_request(method, path, opts, config[:plug])

      is_nil(config[:secret_key]) ->
        {:error, :not_configured}

      true ->
        do_request(method, path, opts, nil)
    end
  end

  defp do_request(method, path, opts, plug) do
    transport_opts = if plug, do: [plug: plug], else: [finch: NursePrep.Finch.Paystack]
    secret_key = Application.fetch_env!(:nurseprep, :paystack)[:secret_key] || "test"

    req =
      ([
         method: method,
         base_url: @base_url,
         url: path,
         auth: {:bearer, secret_key},
         retry: :transient,
         retry_delay: fn attempt -> 50 * (attempt + 1) end,
         max_retries: 2
       ] ++ transport_opts)
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %{status: status, body: %{"status" => true} = body}} when status in 200..299 ->
        {:ok, body["data"]}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
