defmodule NursePrep.Telegram.TelegramClientTest do
  # async: false-this mutates the global `:telegram_api` Application env,
  # matching EvolutionClientTest's reasoning.
  use ExUnit.Case, async: false

  alias NursePrep.Telegram.TelegramClient

  setup do
    original = Application.get_env(:nurseprep, :telegram_api)

    Application.put_env(:nurseprep, :telegram_api,
      bot_token: "test-token",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.put_env(:nurseprep, :telegram_api, original) end)
    :ok
  end

  test "send_text/2 posts chat_id and text to the sendMessage endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/bottest-token/sendMessage"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"chat_id" => 123_456_789, "text" => "hello"}

      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, %{"ok" => true}} = TelegramClient.send_text(123_456_789, "hello")
  end

  test "returns {:error, :not_configured} when bot_token is unset and no test plug is set" do
    Application.put_env(:nurseprep, :telegram_api, bot_token: nil)
    assert TelegramClient.send_text(123_456_789, "hello") == {:error, :not_configured}
  end

  test "returns an error tuple for a non-2xx response" do
    # `stub`, not `expect`: a 500 is retried (retry: :transient, max_retries:
    # 2), so this gets called up to 3 times, not exactly once.
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:http_error, 500, "boom"}} = TelegramClient.send_text(123_456_789, "hello")
  end
end
