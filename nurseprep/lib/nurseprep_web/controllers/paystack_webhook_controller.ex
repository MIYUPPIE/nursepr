defmodule NursePrepWeb.PaystackWebhookController do
  @moduledoc """
  Verifies Paystack's webhook signature (HMAC-SHA512 over the *raw* request
  body-SHA512, not the more commonly assumed SHA256) and enqueues an Oban
  job to process the event, responding 200 quickly either way so Paystack
  doesn't retry a webhook we've already durably recorded.
  """
  use NursePrepWeb, :controller

  alias NursePrep.Subscriptions.Workers.PaystackEventWorker

  def receive(conn, params) do
    raw_body = conn.assigns |> Map.get(:raw_body, []) |> Enum.reverse() |> IO.iodata_to_binary()

    if valid_signature?(conn, raw_body) do
      %{"event" => event_type, "data" => data} = params
      {:ok, _job} = PaystackEventWorker.enqueue(event_type, data)
      send_resp(conn, 200, "")
    else
      send_resp(conn, 401, "")
    end
  end

  defp valid_signature?(conn, raw_body) do
    secret = Application.fetch_env!(:nurseprep, :paystack)[:secret_key]

    with [signature] <- get_req_header(conn, "x-paystack-signature"),
         true <- is_binary(secret) do
      expected = :crypto.mac(:hmac, :sha512, secret, raw_body) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, signature)
    else
      _ -> false
    end
  end
end
