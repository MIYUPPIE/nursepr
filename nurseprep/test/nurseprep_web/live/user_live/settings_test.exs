defmodule NursePrepWeb.UserLive.SettingsTest do
  # async: false — the "Telegram linking" describe block below mutates
  # the process-global `:nurseprep, :telegram_api` Application env.
  use NursePrepWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures

  describe "Settings page" do
    test "renders the profile form", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Your profile"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "profile form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "creates a profile on first save", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#profile_form", %{
          "profile" => %{
            "full_name" => "Ada Nurse",
            "school" => "UNILAG School of Nursing"
          }
        })
        |> render_submit()

      assert result =~ "Profile saved."
      assert result =~ "Ada Nurse"
    end

    test "renders validation errors (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#profile_form")
        |> render_change(%{"profile" => %{"full_name" => ""}})

      assert result =~ "can&#39;t be blank"
    end
  end

  describe "WhatsApp linking" do
    test "an email-only user sees the link-a-number form, not the already-linked state", %{
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> log_in_user(email_user_fixture())
        |> live(~p"/users/settings")

      whatsapp_card = lv |> element("#whatsapp-card") |> render()
      assert whatsapp_card =~ "Add your WhatsApp number"
      refute whatsapp_card =~ "Linked to"
    end

    test "a user with a phone already sees it as linked, not the link form", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      whatsapp_card = lv |> element("#whatsapp-card") |> render()
      assert whatsapp_card =~ "Linked to"
      assert whatsapp_card =~ user.phone
      refute whatsapp_card =~ "Add your WhatsApp number"
    end

    test "requesting a code, then confirming it, links the number and reveals the WhatsApp opt-in checkbox",
         %{conn: conn} do
      user = email_user_fixture()
      phone = unique_user_phone()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      result =
        lv
        |> form("#phone_link_form", %{"phone_link" => %{"phone" => phone}})
        |> render_submit()

      assert result =~ "Code sent! Check WhatsApp."
      assert result =~ phone

      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      result =
        lv
        |> form("#phone_link_code_form", %{"phone_link_code" => %{"code" => code}})
        |> render_submit()

      assert result =~ "WhatsApp number linked!"
      assert result =~ "Linked to"
      assert result =~ phone
      assert result =~ "Send me the daily WhatsApp quiz"

      assert NursePrep.Accounts.get_user_by_phone(phone).id == user.id
    end

    test "confirming with a wrong code shows an error and does not link the number", %{
      conn: conn
    } do
      user = email_user_fixture()
      phone = unique_user_phone()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      lv
      |> form("#phone_link_form", %{"phone_link" => %{"phone" => phone}})
      |> render_submit()

      result =
        lv
        |> form("#phone_link_code_form", %{"phone_link_code" => %{"code" => "000000"}})
        |> render_submit()

      assert result =~ "That code is invalid or expired."
      refute NursePrep.Accounts.get_user!(user.id).phone
    end

    test "requesting a number already linked to a different account shows an error", %{
      conn: conn
    } do
      other = user_fixture()
      user = email_user_fixture()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      result =
        lv
        |> form("#phone_link_form", %{"phone_link" => %{"phone" => other.phone}})
        |> render_submit()

      assert result =~ "already linked to a different account"
      refute NursePrep.Accounts.get_user!(user.id).phone
    end

    test "'Use a different number' returns to the link form", %{conn: conn} do
      user = email_user_fixture()
      phone = unique_user_phone()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      lv
      |> form("#phone_link_form", %{"phone_link" => %{"phone" => phone}})
      |> render_submit()

      result = lv |> element("button", "Use a different number") |> render_click()

      assert result =~ "Add your WhatsApp number"
      refute result =~ "Enter the code sent to"
    end
  end

  describe "Email linking" do
    test "a phone-only user sees the link-an-email form, not the already-linked state", %{
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      email_card = lv |> element("#email-card") |> render()
      assert email_card =~ "Add an email"
      refute email_card =~ "Linked to"
    end

    test "a user with an email already sees it as linked, not the link form", %{conn: conn} do
      user = email_user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      email_card = lv |> element("#email-card") |> render()
      assert email_card =~ "Linked to"
      assert email_card =~ user.email
      refute email_card =~ "Add an email"
    end

    test "requesting a code, then confirming it, links the email to a phone-only account", %{
      conn: conn
    } do
      user = user_fixture()
      email = unique_user_email()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      result =
        lv
        |> form("#email_link_form", %{"email_link" => %{"email" => email}})
        |> render_submit()

      assert result =~ "Code sent! Check your inbox."
      assert result =~ email

      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      result =
        lv
        |> form("#email_link_code_form", %{"email_link_code" => %{"code" => code}})
        |> render_submit()

      assert result =~ "Email linked!"
      assert result =~ email

      assert NursePrep.Accounts.get_user_by_email(email).id == user.id
    end

    test "confirming with a wrong code shows an error and does not link the email", %{
      conn: conn
    } do
      user = user_fixture()
      email = unique_user_email()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      lv
      |> form("#email_link_form", %{"email_link" => %{"email" => email}})
      |> render_submit()

      result =
        lv
        |> form("#email_link_code_form", %{"email_link_code" => %{"code" => "000000"}})
        |> render_submit()

      assert result =~ "That code is invalid or expired."
      refute NursePrep.Accounts.get_user!(user.id).email
    end

    test "requesting an email already linked to a different account shows an error", %{
      conn: conn
    } do
      other = email_user_fixture()
      user = user_fixture()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      result =
        lv
        |> form("#email_link_form", %{"email_link" => %{"email" => other.email}})
        |> render_submit()

      assert result =~ "already linked to a different account"
      refute NursePrep.Accounts.get_user!(user.id).email
    end

    test "'Use a different email' returns to the link form", %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      {:ok, lv, _html} = log_in_user(conn, user) |> live(~p"/users/settings")

      lv
      |> form("#email_link_form", %{"email_link" => %{"email" => email}})
      |> render_submit()

      result = lv |> element("button", "Use a different email") |> render_click()

      assert result =~ "Add an email"
      refute result =~ "Enter the code sent to"
    end
  end

  describe "Telegram linking" do
    setup do
      original = Application.get_env(:nurseprep, :telegram_api)

      Application.put_env(
        :nurseprep,
        :telegram_api,
        Keyword.put(original || [], :bot_username, "nurseprepbot")
      )

      on_exit(fn -> Application.put_env(:nurseprep, :telegram_api, original) end)
      :ok
    end

    test "an unlinked user sees a button to open the bot", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Open the NursePrep Telegram bot"
      assert html =~ "https://t.me/nurseprepbot"
    end

    test "the bot button is a one-tap deep link carrying a link token, not a bare bot URL", %{
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      # A bare bot URL would mean typing a phone/email by hand once inside
      # Telegram-`?start=<token>` (see Messaging.telegram_deep_link/1) is
      # what makes tapping Start alone enough to link.
      assert has_element?(
               lv,
               ~s(#telegram-card a[href^="https://t.me/nurseprepbot?start="][target="_blank"])
             )
    end

    test "a user with telegram_chat_id set sees the linked state instead of the button", %{
      conn: conn
    } do
      user = user_fixture()
      {:ok, user} = NursePrep.Accounts.link_telegram_chat_id(user, 123_456_789)

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      assert html =~ "automatic"
      assert html =~ "backup if WhatsApp is ever unavailable"
      refute html =~ "Open the NursePrep Telegram bot"
    end

    test "unlinking frees the chat id up for a different account to link", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = NursePrep.Accounts.link_telegram_chat_id(user, 123_456_789)

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/users/settings")

      result = lv |> element("button", "Unlink") |> render_click()

      assert result =~ "Telegram unlinked"
      assert result =~ "Open the NursePrep Telegram bot"
      refute NursePrep.Accounts.get_user!(user.id).telegram_chat_id

      # The point of unlinking: this chat id is genuinely free again.
      assert {:ok, _} =
               NursePrep.Accounts.link_telegram_chat_id(user_fixture(), 123_456_789)
    end

    test "hides the button instead of linking to a broken URL when no bot username is configured",
         %{conn: conn} do
      Application.put_env(:nurseprep, :telegram_api, bot_username: nil)

      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      refute html =~ "Open the NursePrep Telegram bot"
    end
  end
end
