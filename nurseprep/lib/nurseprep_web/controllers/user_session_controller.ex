defmodule NursePrepWeb.UserSessionController do
  use NursePrepWeb, :controller

  alias NursePrep.Accounts
  alias NursePrepWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Logged in successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => %{"phone" => phone, "code" => code}} = params, info) do
    finish_login(conn, Accounts.verify_otp(phone, code), params, info)
  end

  defp create(conn, %{"user" => %{"email" => email, "code" => code}} = params, info) do
    finish_login(conn, Accounts.verify_email_otp(email, code), params, info)
  end

  defp finish_login(conn, result, params, info) do
    case result do
      {:ok, {user, _session_token}} ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, params["user"])

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, "Too many attempts. Please wait a few minutes and try again.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :invalid_or_expired} ->
        conn
        |> put_flash(:error, "That code is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
