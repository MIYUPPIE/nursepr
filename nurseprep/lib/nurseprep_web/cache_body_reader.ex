defmodule NursePrepWeb.CacheBodyReader do
  @moduledoc """
  Stashes the raw request body into `conn.assigns.raw_body` before
  `Plug.Parsers` decodes it. Paystack's webhook signature is an HMAC over
  the *exact* raw bytes-re-serializing the parsed JSON map would produce
  different bytes (key order, whitespace) and silently break verification.

  Also defensively substitutes `"{}"` for the Evolution API WhatsApp
  webhook's body (`/webhooks/evolution/*`) when it's malformed JSON or
  larger than `Plug.Parsers`' read limit, instead of letting a
  `Jason.DecodeError`/`Plug.Parsers.RequestTooLargeError` propagate into a
  400/413/500 response. Evolution replays chat history on link/reconnect
  with payloads that are sometimes malformed or oversized by the time they
  reach us, and (per `WhatsappWebhookController`'s moduledoc) retries hard
  on any non-2xx response-up to 10 attempts with backoff-so one bad
  payload could otherwise retry-storm and crowd out later, legitimate
  messages. `WhatsappWebhookController`'s catch-all clause already turns an
  empty `%{}` body into a silent 200, so substituting `"{}"` here is
  exactly the "ignore and move on" behavior Evolution needs. Scoped to
  that one path so Paystack's raw-body/HMAC handling above is untouched.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
        {:ok, sanitize(body, conn), conn}

      {:more, _partial, conn} ->
        if evolution_webhook?(conn) do
          {:ok, "{}", conn}
        else
          raise Plug.Parsers.RequestTooLargeError
        end
    end
  end

  defp sanitize(body, conn) do
    if evolution_webhook?(conn) and not valid_json?(body) do
      "{}"
    else
      body
    end
  end

  defp valid_json?(body) do
    match?({:ok, _}, Jason.decode(body))
  end

  defp evolution_webhook?(%Plug.Conn{path_info: ["webhooks", "evolution" | _]}), do: true
  defp evolution_webhook?(_conn), do: false
end
