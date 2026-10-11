defmodule NursePrepWeb.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  alias NursePrepWeb.CacheBodyReader

  @evolution_path "/webhooks/evolution/some-token"
  @paystack_path "/webhooks/paystack"

  defp conn_with_body(path, body) do
    Plug.Test.conn(:post, path, body)
  end

  test "passes valid JSON through unchanged on the evolution webhook path" do
    body = Jason.encode!(%{"event" => "messages.upsert", "data" => %{}})
    conn = conn_with_body(@evolution_path, body)

    assert {:ok, ^body, _conn} = CacheBodyReader.read_body(conn, [])
  end

  # Evolution replays chat history on link/reconnect with payloads that are
  # sometimes malformed JSON by the time they reach us. Substituting "{}"
  # keeps `Plug.Parsers` from raising, so `WhatsappWebhookController`'s
  # catch-all clause turns it into a silent 200 instead of a 400 that makes
  # Evolution retry-storm the same bad payload.
  test "substitutes {} for malformed JSON on the evolution webhook path" do
    conn = conn_with_body(@evolution_path, "{not valid json")

    assert {:ok, "{}", _conn} = CacheBodyReader.read_body(conn, [])
  end

  test "leaves malformed JSON alone on other paths (e.g. Paystack)" do
    conn = conn_with_body(@paystack_path, "{not valid json")

    assert {:ok, "{not valid json", _conn} = CacheBodyReader.read_body(conn, [])
  end

  test "still caches the raw body into conn.assigns.raw_body for HMAC verification" do
    body = Jason.encode!(%{"event" => "charge.success"})
    conn = conn_with_body(@paystack_path, body)

    assert {:ok, ^body, conn} = CacheBodyReader.read_body(conn, [])
    assert conn.assigns.raw_body == [body]
  end

  test "substitutes {} instead of raising RequestTooLargeError on the evolution webhook path" do
    body = String.duplicate("a", 100)
    conn = conn_with_body(@evolution_path, body)

    assert {:ok, "{}", _conn} = CacheBodyReader.read_body(conn, length: 10, read_length: 10)
  end

  test "still raises RequestTooLargeError on other paths (e.g. Paystack)" do
    body = String.duplicate("a", 100)
    conn = conn_with_body(@paystack_path, body)

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      CacheBodyReader.read_body(conn, length: 10, read_length: 10)
    end
  end
end
