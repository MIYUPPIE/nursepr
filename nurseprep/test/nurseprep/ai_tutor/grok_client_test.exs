defmodule NursePrep.AiTutor.GrokClientTest do
  # async: false-mutates the global :xai Application env.
  use ExUnit.Case, async: false

  alias NursePrep.AiTutor.GrokClient

  setup do
    original = Application.get_env(:nurseprep, :xai)

    Application.put_env(:nurseprep, :xai,
      api_key: "xai-test",
      model: "grok-4",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.put_env(:nurseprep, :xai, original) end)
    :ok
  end

  test "sends the message history with auth headers and returns text + usage" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xai-test"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "grok-4"
      assert [%{"role" => "system", "content" => system} | rest] = decoded["messages"]
      assert system =~ "NursePrep AI Tutor"
      assert rest == [%{"role" => "user", "content" => "What is PHC?"}]

      Req.Test.json(conn, %{
        "model" => "grok-4",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Primary Health Care is..."}}
        ],
        "usage" => %{"prompt_tokens" => 42, "completion_tokens" => 17}
      })
    end)

    assert {:ok, result} = GrokClient.ask([%{role: "user", content: "What is PHC?"}])
    assert result.text == "Primary Health Care is..."
    assert result.tokens_input == 42
    assert result.tokens_output == 17
  end

  test "surfaces a non-200 response as an error tuple" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:http_error, 400, %{"error" => "bad request"}}} =
             GrokClient.ask([%{role: "user", content: "hi"}])
  end

  test "returns {:error, :not_configured} with no api key and no test plug" do
    Application.put_env(:nurseprep, :xai, api_key: nil, model: "grok-4")
    assert GrokClient.ask([%{role: "user", content: "hi"}]) == {:error, :not_configured}
  end
end
