defmodule NursePrepWeb.PaystackWebhookControllerTest do
  use NursePrepWeb.ConnCase, async: false
  use Oban.Testing, repo: NursePrep.Repo

  alias NursePrep.Subscriptions.Payment
  alias NursePrep.{Repo, AccountsFixtures}

  @secret "whsec_test_secret"

  setup do
    original = Application.get_env(:nurseprep, :paystack)
    Application.put_env(:nurseprep, :paystack, Keyword.put(original || [], :secret_key, @secret))
    on_exit(fn -> Application.put_env(:nurseprep, :paystack, original) end)
    :ok
  end

  test "accepts a correctly-signed payload and enqueues processing", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, payment} =
      %Payment{}
      |> Payment.changeset(%{
        "user_id" => user.id,
        "paystack_reference" => "ref-123",
        "amount_kobo" => 500_000,
        "status" => "pending"
      })
      |> Repo.insert()

    body =
      Jason.encode!(%{
        "event" => "charge.success",
        "data" => %{"reference" => payment.paystack_reference, "customer" => %{}}
      })

    signature = sign(body)

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-paystack-signature", signature)
      |> post(~p"/webhooks/paystack", body)

    assert response(conn, 200)

    assert_enqueued(
      worker: NursePrep.Subscriptions.Workers.PaystackEventWorker,
      args: %{
        "event_type" => "charge.success",
        "data" => %{"reference" => payment.paystack_reference, "customer" => %{}}
      }
    )
  end

  test "rejects a tampered payload with a mismatched signature", %{conn: conn} do
    body = Jason.encode!(%{"event" => "charge.success", "data" => %{"reference" => "whatever"}})
    wrong_signature = sign(~s({"event":"something else"}))

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-paystack-signature", wrong_signature)
      |> post(~p"/webhooks/paystack", body)

    assert response(conn, 401)
  end

  test "rejects a request with no signature header at all", %{conn: conn} do
    body = Jason.encode!(%{"event" => "charge.success", "data" => %{}})

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/paystack", body)

    assert response(conn, 401)
  end

  # The single most common mistake integrating Paystack webhooks is signing
  # with SHA256 (the more familiar default for HMAC webhooks generally) —
  # Paystack actually requires SHA512. A signature computed the "usual" way
  # must still be rejected, or a regression here would silently accept
  # signatures that don't actually prove Paystack sent the request.
  test "rejects a signature computed with SHA256 instead of the required SHA512", %{conn: conn} do
    body = Jason.encode!(%{"event" => "charge.success", "data" => %{"reference" => "whatever"}})
    sha256_signature = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-paystack-signature", sha256_signature)
      |> post(~p"/webhooks/paystack", body)

    assert response(conn, 401)
  end

  test "fails closed (401, not a crash) when no secret key is configured", %{conn: conn} do
    Application.put_env(:nurseprep, :paystack, Keyword.put([], :secret_key, nil))

    body = Jason.encode!(%{"event" => "charge.success", "data" => %{"reference" => "whatever"}})

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-paystack-signature", sign(body))
      |> post(~p"/webhooks/paystack", body)

    assert response(conn, 401)
  end

  defp sign(body), do: :crypto.mac(:hmac, :sha512, @secret, body) |> Base.encode16(case: :lower)
end
