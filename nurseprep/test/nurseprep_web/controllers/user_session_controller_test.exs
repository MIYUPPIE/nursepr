defmodule NursePrepWeb.UserSessionControllerTest do
  use NursePrepWeb.ConnCase, async: true

  import NursePrep.AccountsFixtures
  alias NursePrep.Accounts

  describe "POST /users/log-in - phone + OTP" do
    test "logs the user in with a valid code", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"phone" => phone, "code" => code}})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/dashboard"

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/dashboard"

      conn = get(conn, ~p"/dashboard")
      response = html_response(conn, 200)
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "confirms a brand-new user on first successful verification", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, user, :whatsapp} = Accounts.request_otp(phone)
      refute user.confirmed_at
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"phone" => phone, "code" => code}})

      assert get_session(conn, :user_token)
      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "redirects to login page with an invalid code", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"phone" => phone, "code" => "000000"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That code is invalid or has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - email + OTP" do
    test "logs the user in with a valid code", %{conn: conn} do
      email = unique_user_email()
      {:ok, _user, :email} = Accounts.request_email_otp(email)
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => email, "code" => code}})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "confirms a brand-new phone-less user on first successful verification", %{conn: conn} do
      email = unique_user_email()
      {:ok, user, :email} = Accounts.request_email_otp(email)
      refute user.confirmed_at
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => email, "code" => code}})

      assert get_session(conn, :user_token)
      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "redirects to login page with an invalid code", %{conn: conn} do
      email = unique_user_email()
      {:ok, _user, :email} = Accounts.request_email_otp(email)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => email, "code" => "000000"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That code is invalid or has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
