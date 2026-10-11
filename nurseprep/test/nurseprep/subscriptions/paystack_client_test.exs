defmodule NursePrep.Subscriptions.PaystackClientTest do
  # async: false-mutates the global :paystack Application env.
  use ExUnit.Case, async: false

  alias NursePrep.Subscriptions.PaystackClient

  setup do
    original = Application.get_env(:nurseprep, :paystack)

    Application.put_env(:nurseprep, :paystack,
      secret_key: "sk_test_123",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.put_env(:nurseprep, :paystack, original) end)
    :ok
  end

  test "initialize_transaction/3 authenticates with the secret key and returns the authorization data" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/transaction/initialize"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_test_123"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["email"] == "2348012345678@users.nurseprep.ng"
      assert decoded["amount"] == 500_000
      assert decoded["callback_url"] == NursePrepWeb.Endpoint.url() <> "/subscription/callback"

      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{
          "authorization_url" => "https://paystack.test/pay/xyz",
          "reference" => decoded["reference"]
        }
      })
    end)

    user = %{phone: "+2348012345678", email: nil}
    assert {:ok, data} = PaystackClient.initialize_transaction(user, 500_000, "ref-1")
    assert data["authorization_url"] == "https://paystack.test/pay/xyz"
  end

  test "initialize_transaction/3 uses the user's real email when one exists" do
    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["email"] == "ada@example.com"

      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{"authorization_url" => "https://paystack.test/pay/xyz", "reference" => "r"}
      })
    end)

    user = %{phone: nil, email: "ada@example.com"}
    assert {:ok, _data} = PaystackClient.initialize_transaction(user, 500_000, "ref-2")
  end

  test "verify_transaction/1 GETs the reference-scoped endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/transaction/verify/ref-1"
      Req.Test.json(conn, %{"status" => true, "data" => %{"status" => "success"}})
    end)

    assert {:ok, %{"status" => "success"}} = PaystackClient.verify_transaction("ref-1")
  end

  test "surfaces a Paystack-reported failure as an error tuple" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"status" => false, "message" => "Invalid key"})
    end)

    assert {:error, {:http_error, 200, %{"status" => false}}} =
             PaystackClient.verify_transaction("ref-1")
  end

  test "returns {:error, :not_configured} with no secret key and no test plug" do
    Application.put_env(:nurseprep, :paystack, secret_key: nil)
    assert PaystackClient.verify_transaction("ref-1") == {:error, :not_configured}
  end
end
