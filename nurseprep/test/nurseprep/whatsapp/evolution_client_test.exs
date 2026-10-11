defmodule NursePrep.Whatsapp.EvolutionClientTest do
  # async: false-this mutates the global `:evolution_api` Application env,
  # which isn't safe to race against other test files doing the same
  # (the webhook controller test also touches it).
  use ExUnit.Case, async: false

  alias NursePrep.Whatsapp.EvolutionClient

  setup do
    original = Application.get_env(:nurseprep, :evolution_api)

    Application.put_env(:nurseprep, :evolution_api,
      base_url: "http://evolution.test",
      instance: "nurseprep",
      api_key: "test-key",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.put_env(:nurseprep, :evolution_api, original) end)
    :ok
  end

  test "send_text/2 posts to the instance-scoped endpoint with the apikey header" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/message/sendText/nurseprep"
      assert Plug.Conn.get_req_header(conn, "apikey") == ["test-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"number" => "+2348012345678", "text" => "hello"}

      Req.Test.json(conn, %{"status" => "sent"})
    end)

    assert {:ok, %{"status" => "sent"}} = EvolutionClient.send_text("+2348012345678", "hello")
  end

  test "returns {:error, :not_configured} when base_url/api_key are unset and no test plug is set" do
    Application.put_env(:nurseprep, :evolution_api, base_url: nil, instance: nil, api_key: nil)
    assert EvolutionClient.send_text("+2348012345678", "hello") == {:error, :not_configured}
  end

  test "returns an error tuple for a non-2xx response" do
    # `stub`, not `expect`: a 500 is retried (retry: :transient, max_retries:
    # 2), so this gets called up to 3 times, not exactly once.
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:http_error, 500, "boom"}} =
             EvolutionClient.send_text("+2348012345678", "hello")
  end

  test "send_buttons/3 builds Evolution's documented button payload shape" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/message/sendButtons/nurseprep"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "number" => "+2348012345678",
               "title" => "Pick one",
               "buttons" => [%{"buttonId" => "a", "buttonText" => %{"displayText" => "Option A"}}]
             }

      Req.Test.json(conn, %{})
    end)

    assert {:ok, _} =
             EvolutionClient.send_buttons("+2348012345678", "Pick one", [{"a", "Option A"}])
  end

  describe "connection_state/0" do
    test "GETs the instance-scoped endpoint and extracts the state string" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/instance/connectionState/nurseprep"

        Req.Test.json(conn, %{"instance" => %{"instanceName" => "nurseprep", "state" => "close"}})
      end)

      assert EvolutionClient.connection_state() == {:ok, "close"}
    end

    test "returns an error for an unexpected response shape" do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, {:unexpected_response, %{"unexpected" => true}}} =
               EvolutionClient.connection_state()
    end

    test "returns {:error, :not_configured} when unset and no test plug is set" do
      Application.put_env(:nurseprep, :evolution_api, base_url: nil, instance: nil, api_key: nil)
      assert EvolutionClient.connection_state() == {:error, :not_configured}
    end
  end
end
