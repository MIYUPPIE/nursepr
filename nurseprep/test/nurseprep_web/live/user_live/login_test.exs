defmodule NursePrepWeb.UserLive.LoginTest do
  # async: false. The "otp_sender isn't wired up" describe block below
  # flips `:nurseprep, :otp_sender` via `Application.put_env/3`, which is
  # process-global state. Under `async: true` that raced every other
  # concurrently-running async test that touches OTP/`user_fixture` (they'd
  # transiently see `otp_sender: Log` instead of `OtpSender.Test`), which
  # surfaced as unrelated-looking failures across most of the suite. The
  # same reasoning now also covers `:telegram_api` and
  # `Whatsapp.ConnectionAlert`, both flipped by `with_telegram_bot/1` and
  # `with_whatsapp_down/1` below.
  use NursePrepWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NursePrep.AccountsFixtures

  describe "login page" do
    test "renders the WhatsApp tab first", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Welcome to NursePrep"
      assert html =~ "WhatsApp number"
    end

    test "switching to the email tab shows the email form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html = lv |> element("button[phx-value-channel=email]") |> render_click()

      assert html =~ "Email address"
      refute html =~ "WhatsApp number"
    end

    test "shows only WhatsApp and Email tabs when no Telegram bot is configured", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "button[phx-value-channel=phone]", "WhatsApp")
      assert has_element?(lv, "button[phx-value-channel=email]", "Email")
      refute has_element?(lv, "button[phx-value-channel=telegram]")
    end

    test "shows all three tabs, in order, once a Telegram bot is configured", %{conn: conn} do
      with_telegram_bot(fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        assert has_element?(lv, "button[phx-value-channel=phone]", "WhatsApp")
        assert has_element?(lv, "button[phx-value-channel=telegram]", "Telegram")
        assert has_element?(lv, "button[phx-value-channel=email]", "Email")
      end)
    end
  end

  describe "requesting a code" do
    test "advances to the code step and delivers a code", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        lv
        |> form("#phone_form", user: %{phone: phone})
        |> render_submit()

      assert html =~ "Login code"
      assert NursePrep.Accounts.OtpSender.Test.last_code(phone)
    end

    test "shows an error for an invalid phone number", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        lv
        |> form("#phone_form", user: %{phone: "not a phone"})
        |> render_submit()

      assert html =~ "look like a valid WhatsApp number"
    end

    test "the email tab advances to the code step and delivers a code", %{conn: conn} do
      email = unique_user_email()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("button[phx-value-channel=email]") |> render_click()

      html =
        lv
        |> form("#email_form", user: %{email: email})
        |> render_submit()

      assert html =~ "Login code"
      assert html =~ email
      assert NursePrep.Accounts.EmailOtpSender.Test.last_code(email)
    end

    test "shows an error for an invalid email address", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("button[phx-value-channel=email]") |> render_click()

      html =
        lv
        |> form("#email_form", user: %{email: "not an email"})
        |> render_submit()

      assert html =~ "look like a valid email address"
    end

    test "WhatsApp down points to the Email tab when no Telegram bot is configured", %{conn: conn} do
      with_whatsapp_down(fn ->
        phone = unique_user_phone()
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        html =
          lv
          |> form("#phone_form", user: %{phone: phone})
          |> render_submit()

        assert html =~ "WhatsApp is temporarily unavailable"
        assert html =~ "Try the Email tab instead"

        # No modal, no deep link — the old nudge is gone entirely, and
        # this deployment has nothing Telegram-shaped to point at anyway.
        refute has_element?(lv, "#telegram-nudge-modal")
        refute html =~ "t.me"
      end)
    end

    test "WhatsApp down points to both Telegram and Email tabs once a bot is configured", %{
      conn: conn
    } do
      with_telegram_bot(fn ->
        with_whatsapp_down(fn ->
          phone = unique_user_phone()
          {:ok, lv, _html} = live(conn, ~p"/users/log-in")

          html =
            lv
            |> form("#phone_form", user: %{phone: phone})
            |> render_submit()

          assert html =~ "WhatsApp is temporarily unavailable"
          assert html =~ "Try the Telegram or Email tab instead"
          refute has_element?(lv, "#telegram-nudge-modal")
        end)
      end)
    end

    # The flash used to depend on this exact phone's own account state
    # (does it have an email on file, does it already have Telegram
    # linked) because the old nudge pointed at a link token minted just
    # for that one number. Now that Telegram is a tab anyone can reach on
    # their own, the flash only depends on which tabs this deployment
    # offers — not on anything about the student typing in.
    test "the flash doesn't change based on whether this phone already has an email on file", %{
      conn: conn
    } do
      phone = unique_user_phone()
      user = user_fixture(%{phone: phone})
      {:ok, _user} = NursePrep.Accounts.update_user_email(user, unique_user_email())

      with_telegram_bot(fn ->
        with_whatsapp_down(fn ->
          {:ok, lv, _html} = live(conn, ~p"/users/log-in")

          html =
            lv
            |> form("#phone_form", user: %{phone: phone})
            |> render_submit()

          assert html =~ "Try the Telegram or Email tab instead"
        end)
      end)
    end
  end

  describe "Telegram tab (cold login)" do
    test "does not appear when no bot is configured", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      refute has_element?(lv, "button[phx-value-channel=telegram]")
    end

    test "shows a tappable deep link immediately, with no phone or email typed on this page first",
         %{conn: conn} do
      with_telegram_bot(fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        lv |> element("button[phx-value-channel=telegram]") |> render_click()

        # `cold:`-prefixed (see `Accounts.build_cold_telegram_login_token/0`)
        # and a real, tappable link, not inert text inside the
        # auto-dismissing flash toast.
        assert has_element?(
                 lv,
                 ~s(a[href^="https://t.me/nurseprepbot?start=cold:"][target="_blank"]),
                 "Open the NursePrep Telegram bot"
               )
      end)
    end

    # Regression coverage for the "OTP can't be used at that instant"
    # class of bug: tapping the deep link and typing a phone/email happens
    # entirely inside the Telegram app, a different process from this tab
    # — this proves the page jumps to the code step on its own once
    # `Whatsapp.Session.deliver_cold_login_otp/3` broadcasts, no reload or
    # resubmit involved.
    test "jumps to the code step for a phone identifier once the bot finishes the cold link", %{
      conn: conn
    } do
      with_telegram_bot(fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")
        html = lv |> element("button[phx-value-channel=telegram]") |> render_click()

        [_, token] = Regex.run(~r/start=([^"]+)"/, html)
        phone = unique_user_phone()

        Phoenix.PubSub.broadcast(
          NursePrep.PubSub,
          NursePrep.Accounts.telegram_link_topic(token),
          {:telegram_cold_login_completed, :phone, phone}
        )

        html = render(lv)
        assert html =~ "Login code"
        assert html =~ "Check Telegram"
      end)
    end

    test "jumps to the code step for an email identifier once the bot finishes the cold link", %{
      conn: conn
    } do
      with_telegram_bot(fn ->
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")
        html = lv |> element("button[phx-value-channel=telegram]") |> render_click()

        [_, token] = Regex.run(~r/start=([^"]+)"/, html)
        email = unique_user_email()

        Phoenix.PubSub.broadcast(
          NursePrep.PubSub,
          NursePrep.Accounts.telegram_link_topic(token),
          {:telegram_cold_login_completed, :email, email}
        )

        html = render(lv)
        assert html =~ "Login code"
        assert html =~ email
        assert html =~ "Check Telegram"
      end)
    end
  end

  describe "email tab Telegram preference" do
    import Mox

    setup :set_mox_global
    setup :verify_on_exit!

    # Regression coverage at the UI layer for the same gap fixed in
    # `Accounts.request_email_otp/1`: an email-primary account (no phone,
    # so the phone tab's WhatsApp-down nudge never applies to it) with a
    # linked Telegram had no path to a Telegram-delivered code at all-the
    # Email tab always sent to email, full stop.
    test "advances to the code step over Telegram once this email has one linked", %{conn: conn} do
      user = email_user_fixture()
      email_code_before_linking = NursePrep.Accounts.EmailOtpSender.Test.last_code(user.email)
      {:ok, user} = NursePrep.Accounts.link_telegram_chat_id(user, 888_888_888)

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn 888_888_888, _text ->
        {:ok, %{}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("button[phx-value-channel=email]") |> render_click()

      html =
        lv
        |> form("#email_form", user: %{email: user.email})
        |> render_submit()

      assert html =~ "Login code"
      assert html =~ "Check Telegram"

      # No second email went out-the code on file is still the one from
      # account creation, before Telegram was linked.
      assert NursePrep.Accounts.EmailOtpSender.Test.last_code(user.email) ==
               email_code_before_linking
    end
  end

  describe "submitting a code" do
    test "logs the user in with the correct code", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      lv |> form("#phone_form", user: %{phone: phone}) |> render_submit()
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      form = form(lv, "#code_form", user: %{phone: phone, code: code})
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "shows a flash error for the wrong code", %{conn: conn} do
      phone = unique_user_phone()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      lv |> form("#phone_form", user: %{phone: phone}) |> render_submit()

      form = form(lv, "#code_form", user: %{phone: phone, code: "000000"})
      conn = submit_form(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That code is invalid or has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "logs the user in via the email tab with the correct code", %{conn: conn} do
      email = unique_user_email()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("button[phx-value-channel=email]") |> render_click()

      lv |> form("#email_form", user: %{email: email}) |> render_submit()
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      form = form(lv, "#code_form", user: %{email: email, code: code})
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/dashboard"
    end
  end

  describe "when WhatsApp isn't wired up (otp_sender is the Log fallback)" do
    setup do
      previous = Application.get_env(:nurseprep, :otp_sender)
      Application.put_env(:nurseprep, :otp_sender, NursePrep.Accounts.OtpSender.Log)
      on_exit(fn -> Application.put_env(:nurseprep, :otp_sender, previous) end)
      :ok
    end

    test "hides the WhatsApp tab and form entirely, defaulting straight to Email", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      refute has_element?(lv, "button[phx-value-channel=phone]")
      refute has_element?(lv, "#phone_form")
      assert html =~ "Email address"

      # One available channel means there's nothing to switch between —
      # no tab bar at all, not a single inert tab.
      refute has_element?(lv, "div.tabs-box")
    end
  end

  describe "when email isn't wired up (email_otp_sender is the Log fallback)" do
    setup do
      previous = Application.get_env(:nurseprep, :email_otp_sender)
      Application.put_env(:nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Log)
      on_exit(fn -> Application.put_env(:nurseprep, :email_otp_sender, previous) end)
      :ok
    end

    test "tells the user to check server logs instead of their inbox", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("button[phx-value-channel=email]") |> render_click()

      email = unique_user_email()

      html =
        lv
        |> form("#email_form", user: %{email: email})
        |> render_submit()

      refute html =~ "Check your inbox"
      assert html =~ "wired up in this environment"
      assert html =~ "Dev mode"
    end
  end

  describe "re-authentication" do
    test "an already logged-in user can still reach the login page", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Welcome to NursePrep"
    end
  end

  defp with_telegram_bot(fun) do
    previous = Application.get_env(:nurseprep, :telegram_api)

    Application.put_env(:nurseprep, :telegram_api,
      bot_token: "test-token",
      webhook_secret: "test-secret",
      bot_username: "nurseprepbot"
    )

    try do
      fun.()
    after
      Application.put_env(:nurseprep, :telegram_api, previous)
    end
  end

  defp with_whatsapp_down(fun) do
    NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
      "state" => "close",
      "statusReason" => 401
    })

    try do
      fun.()
    after
      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})
    end
  end
end
