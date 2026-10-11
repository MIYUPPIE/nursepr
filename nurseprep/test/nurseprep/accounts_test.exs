defmodule NursePrep.AccountsTest do
  use NursePrep.DataCase

  alias NursePrep.Accounts
  alias NursePrep.Accounts.{User, UserToken}

  import NursePrep.AccountsFixtures
  import NursePrep.Factory

  describe "get_user_by_phone/1" do
    test "does not return a user for an unknown phone" do
      refute Accounts.get_user_by_phone("+2348011111111")
    end

    test "returns the user if the phone exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_phone(user.phone)
    end
  end

  describe "get_user_by_email/1" do
    test "does not return a user for an unknown email" do
      refute Accounts.get_user_by_email("nobody@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = email_user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(-1) end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "request_otp/1" do
    test "creates a new user on first request and delivers a code" do
      phone = unique_user_phone()
      assert {:ok, user, :whatsapp} = Accounts.request_otp(phone)
      assert user.phone == phone
      refute user.confirmed_at

      assert code = NursePrep.Accounts.OtpSender.Test.last_code(phone)
      assert String.length(code) == 6

      assert user_token = Repo.get_by(UserToken, user_id: user.id, context: "otp")
      assert user_token.sent_to == phone
    end

    test "reuses the existing user on a second request" do
      phone = unique_user_phone()
      {:ok, user1, :whatsapp} = Accounts.request_otp(phone)
      {:ok, user2, :whatsapp} = Accounts.request_otp(phone)
      assert user1.id == user2.id
    end

    test "accepts a local Nigerian format and normalizes to E.164" do
      assert {:ok, user, :whatsapp} = Accounts.request_otp("08031234567")
      assert user.phone == "+2348031234567"
    end

    test "rejects an invalid phone number" do
      assert {:error, _reason} = Accounts.request_otp("not a phone number")
    end

    test "rate-limits repeated requests for the same phone" do
      phone = unique_user_phone()
      assert {:ok, _, :whatsapp} = Accounts.request_otp(phone)
      assert {:ok, _, :whatsapp} = Accounts.request_otp(phone)
      assert {:ok, _, :whatsapp} = Accounts.request_otp(phone)
      assert {:error, :rate_limited} = Accounts.request_otp(phone)
    end

    test "surfaces a delivery failure instead of silently reporting success" do
      phone = NursePrep.Accounts.OtpSender.Test.failing_phone()
      assert {:error, :delivery_failed} = Accounts.request_otp(phone)
      refute NursePrep.Accounts.OtpSender.Test.last_code(phone)
    end
  end

  describe "request_otp/1 WhatsApp-down fallback" do
    import Mox

    setup :set_mox_global
    setup :verify_on_exit!

    setup do
      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})

      on_exit(fn ->
        NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{"state" => "open"})
      end)

      :ok
    end

    # The regression test for the sent_to/delivery-target trap: a naive
    # implementation could set `sent_to` to the tagged Telegram identity
    # instead of the real phone, which would make the code permanently
    # unverifiable since the login UI always re-submits the phone the
    # student typed, never the delivery channel.
    test "falls back to Telegram when WhatsApp is down and this user already linked one, and the code still verifies by phone" do
      phone = unique_user_phone()
      user = user_fixture(%{phone: phone})
      {:ok, user} = Accounts.link_telegram_chat_id(user, 555_555_555)

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn 555_555_555, text ->
        send(test_pid, {:telegram_text, text})
        {:ok, %{}}
      end)

      assert {:ok, requested_user, :telegram} = Accounts.request_otp(phone)
      assert requested_user.id == user.id
      assert_receive {:telegram_text, text}, 1000

      user_token = Repo.get_by!(UserToken, user_id: user.id, context: "otp")
      assert user_token.sent_to == phone

      [code] = Regex.run(~r/\d{6}/, text, capture: :first)
      assert {:ok, {_confirmed, _session_token}} = Accounts.verify_otp(phone, code)
    end

    test "returns {:error, :whatsapp_unavailable} when WhatsApp is down, no Telegram is linked, but this user has an email on file" do
      phone = unique_user_phone()
      user = user_fixture(%{phone: phone})
      {:ok, _user} = Accounts.update_user_email(user, unique_user_email())

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      assert {:error, :whatsapp_unavailable} = Accounts.request_otp(phone)
    end

    test "returns {:error, :whatsapp_unavailable_no_fallback, token} when WhatsApp is down and this user has neither Telegram nor an email" do
      phone = unique_user_phone()
      {:ok, user, :whatsapp} = Accounts.request_otp(phone)

      NursePrep.Whatsapp.ConnectionAlert.handle_state_update(%{
        "state" => "close",
        "statusReason" => 401
      })

      assert {:error, :whatsapp_unavailable_no_fallback, token} = Accounts.request_otp(phone)
      assert is_binary(token)

      # Confirming it is enough to link Telegram, tagged `:login` so the
      # caller (Whatsapp.Session) knows to follow up with a login OTP-see
      # the "Telegram contacts" describe block in session_test.exs for the
      # full tap-to-code flow, since ordering that follow-up send is
      # Session's job, not this function's (see its doc).
      assert {:ok, linked_user, :login} = Accounts.confirm_telegram_link_token(token, 909_090)
      assert linked_user.id == user.id
      assert linked_user.telegram_chat_id == 909_090
    end

    test "confirm_telegram_link_token rejects an invalid or expired token" do
      assert {:error, :invalid_or_expired} =
               Accounts.confirm_telegram_link_token("not-a-real-token", 123_456)
    end

    test "request_telegram_link_token (Settings-initiated) does not send a login OTP on confirm" do
      user = email_user_fixture()
      token = Accounts.request_telegram_link_token(user)

      assert {:ok, linked_user, :settings} = Accounts.confirm_telegram_link_token(token, 424_242)
      assert linked_user.id == user.id
      assert linked_user.telegram_chat_id == 424_242
    end

    test "requesting a fresh telegram link token invalidates the earlier unused one" do
      user = email_user_fixture()
      stale_token = Accounts.request_telegram_link_token(user)
      fresh_token = Accounts.request_telegram_link_token(user)

      assert {:error, :invalid_or_expired} =
               Accounts.confirm_telegram_link_token(stale_token, 100_001)

      assert {:ok, _linked_user, :settings} =
               Accounts.confirm_telegram_link_token(fresh_token, 100_002)
    end

    test "rejects a telegram link token older than the 30-minute window" do
      user = email_user_fixture()
      token = Accounts.request_telegram_link_token(user)

      Repo.update_all(from(t in UserToken, where: t.context == "telegram_link"),
        set: [inserted_at: ~N[2020-01-01 00:00:00]]
      )

      assert {:error, :invalid_or_expired} = Accounts.confirm_telegram_link_token(token, 100_003)
    end

    # The regression test for the actual production bug: the same
    # Telegram account already linked to account A taps a deep link
    # issued for account B. This must fail with a *named* reason, not the
    # generic :invalid_or_expired-see confirm_telegram_link_token/2's doc
    # for why the fix (unlink, then relink) is completely different from
    # "request a fresh token."
    test "confirming a token for a chat_id already linked to a different account is named distinctly" do
      already_linked = user_fixture()
      {:ok, already_linked} = Accounts.link_telegram_chat_id(already_linked, 555_000_111)

      other_user = email_user_fixture()
      token = Accounts.request_telegram_link_token(other_user)

      assert {:error, :chat_already_linked} =
               Accounts.confirm_telegram_link_token(token, 555_000_111)

      # Neither account changed: the already-linked one keeps its chat,
      # the requester's account gets nothing.
      assert Accounts.get_user!(already_linked.id).telegram_chat_id == 555_000_111
      refute Accounts.get_user!(other_user.id).telegram_chat_id
    end
  end

  describe "verify_otp/2" do
    test "logs in and confirms a brand-new user with the correct code" do
      phone = unique_user_phone()
      {:ok, user, :whatsapp} = Accounts.request_otp(phone)
      refute user.confirmed_at
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      assert {:ok, {confirmed_user, session_token}} = Accounts.verify_otp(phone, code)
      assert confirmed_user.id == user.id
      assert confirmed_user.confirmed_at
      assert is_binary(session_token)
    end

    test "invalidates the code after one use" do
      phone = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      assert {:ok, _} = Accounts.verify_otp(phone, code)
      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone, code)
    end

    test "rejects a wrong code" do
      phone = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone)
      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone, "000000")
    end

    test "rejects an expired code" do
      phone = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone, code)
    end

    test "a code sent for one phone cannot verify a different phone" do
      phone_a = unique_user_phone()
      phone_b = unique_user_phone()
      {:ok, _user, :whatsapp} = Accounts.request_otp(phone_a)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone_a)

      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone_b, code)
    end
  end

  describe "request_email_otp/1" do
    test "creates a new phone-less user on first request and delivers a code over email" do
      email = unique_user_email()
      assert {:ok, user, :email} = Accounts.request_email_otp(email)
      assert user.email == email
      refute user.phone
      refute user.confirmed_at

      assert code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)
      assert String.length(code) == 6

      assert user_token = Repo.get_by(UserToken, user_id: user.id, context: "otp")
      assert user_token.sent_to == email
    end

    test "reuses the existing user on a second request" do
      email = unique_user_email()
      {:ok, user1, :email} = Accounts.request_email_otp(email)
      {:ok, user2, :email} = Accounts.request_email_otp(email)
      assert user1.id == user2.id
    end

    test "normalizes case and surrounding whitespace" do
      suffix = System.unique_integer([:positive, :monotonic])
      assert {:ok, user, :email} = Accounts.request_email_otp("  Student#{suffix}@Example.COM  ")
      assert user.email == "student#{suffix}@example.com"
    end

    test "rejects an invalid email address" do
      assert {:error, _reason} = Accounts.request_email_otp("not an email")
    end

    test "rate-limits repeated requests for the same address" do
      email = unique_user_email()
      assert {:ok, _, :email} = Accounts.request_email_otp(email)
      assert {:ok, _, :email} = Accounts.request_email_otp(email)
      assert {:ok, _, :email} = Accounts.request_email_otp(email)
      assert {:error, :rate_limited} = Accounts.request_email_otp(email)
    end
  end

  describe "request_email_otp/1 Telegram preference" do
    import Mox

    setup :set_mox_global
    setup :verify_on_exit!

    # Regression coverage for a real gap: an email-primary account (no
    # phone at all, see `User.identifier/1`) had no WhatsApp leg to fall
    # back *from*, so `request_email_otp/1` never even looked at
    # `telegram_chat_id`-Telegram was unreachable from the Email tab no
    # matter what, even for a student who'd already linked it.
    test "prefers Telegram over email once this user has linked it" do
      email = unique_user_email()
      {:ok, user, :email} = Accounts.request_email_otp(email)
      email_code_before_linking = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)
      {:ok, user} = Accounts.link_telegram_chat_id(user, 777_777_777)

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn 777_777_777, _text ->
        {:ok, %{}}
      end)

      assert {:ok, requested_user, :telegram} = Accounts.request_email_otp(email)
      assert requested_user.id == user.id

      # No second email went out-the code on file is still the one from
      # before Telegram was linked.
      assert NursePrep.Accounts.EmailOtpSender.Test.last_code(email) == email_code_before_linking
    end

    test "keeps sending over email if this user has never linked Telegram" do
      email = unique_user_email()
      assert {:ok, _user, :email} = Accounts.request_email_otp(email)
      assert NursePrep.Accounts.EmailOtpSender.Test.last_code(email)
    end
  end

  describe "build_cold_telegram_login_token/0 and cold_telegram_login_token?/1" do
    test "mints a token that round-trips as cold, and is unguessably random across calls" do
      token = Accounts.build_cold_telegram_login_token()
      assert Accounts.cold_telegram_login_token?(token)
      refute token == Accounts.build_cold_telegram_login_token()
    end

    test "a UserToken-backed telegram link token (settings/login-purpose) is never mistaken for a cold one" do
      user = user_fixture()
      token = Accounts.request_telegram_link_token(user)
      refute Accounts.cold_telegram_login_token?(token)
    end

    # Telegram's own `/start` deep-link payload is capped at 64 characters
    # (`[A-Za-z0-9_-]`)-a cold token that grew past that would silently
    # break the login page's deep link.
    test "fits Telegram's 64-character /start payload limit" do
      assert String.length(Accounts.build_cold_telegram_login_token()) <= 64
    end
  end

  describe "send_telegram_login_email_otp/1" do
    import Mox

    setup :set_mox_global
    setup :verify_on_exit!

    test "sends the code to the linked Telegram chat, keyed against the email" do
      user = email_user_fixture()
      {:ok, user} = Accounts.link_telegram_chat_id(user, 999_999_999)
      test_pid = self()

      expect(NursePrep.Telegram.TelegramClientMock, :send_text, fn 999_999_999, text ->
        send(test_pid, {:sent, text})
        {:ok, %{}}
      end)

      assert {:ok, _user} = Accounts.send_telegram_login_email_otp(user)

      assert_receive {:sent, text}
      [code] = Regex.run(~r/code is (\d{6})\./, text, capture: :all_but_first)

      # The code verifies against the email (`sent_to`), not the chat id-
      # `deliver_otp/4`'s contract (see its doc comment).
      assert {:ok, {_authed_user, _session_token}} = Accounts.verify_email_otp(user.email, code)
    end
  end

  describe "verify_email_otp/2" do
    test "logs in and confirms a brand-new user with the correct code" do
      email = unique_user_email()
      {:ok, user, :email} = Accounts.request_email_otp(email)
      refute user.confirmed_at
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:ok, {confirmed_user, session_token}} = Accounts.verify_email_otp(email, code)
      assert confirmed_user.id == user.id
      assert confirmed_user.confirmed_at
      assert is_binary(session_token)
    end

    test "invalidates the code after one use" do
      email = unique_user_email()
      {:ok, _user, :email} = Accounts.request_email_otp(email)
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:ok, _} = Accounts.verify_email_otp(email, code)
      assert {:error, :invalid_or_expired} = Accounts.verify_email_otp(email, code)
    end

    test "rejects a wrong code" do
      email = unique_user_email()
      {:ok, _user, :email} = Accounts.request_email_otp(email)
      assert {:error, :invalid_or_expired} = Accounts.verify_email_otp(email, "000000")
    end

    test "a code sent for one email cannot verify a different email" do
      email_a = unique_user_email()
      email_b = unique_user_email()
      {:ok, _user, :email} = Accounts.request_email_otp(email_a)
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email_a)

      assert {:error, :invalid_or_expired} = Accounts.verify_email_otp(email_b, code)
    end

    test "a phone OTP code cannot verify an email login and vice versa" do
      phone = unique_user_phone()
      email = unique_user_email()
      {:ok, _, :whatsapp} = Accounts.request_otp(phone)
      {:ok, _, :email} = Accounts.request_email_otp(email)

      phone_code = NursePrep.Accounts.OtpSender.Test.last_code(phone)
      email_code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:error, :invalid_or_expired} = Accounts.verify_email_otp(email, phone_code)
      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone, email_code)
    end
  end

  describe "request_phone_link/2 and confirm_phone_link/3" do
    test "sends a code over WhatsApp and links the phone to the account on confirmation" do
      user = email_user_fixture()
      phone = unique_user_phone()

      assert {:ok, ^phone} = Accounts.request_phone_link(user, phone)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      assert {:ok, updated_user} = Accounts.confirm_phone_link(user, phone, code)
      assert updated_user.id == user.id
      assert updated_user.phone == phone
      assert Accounts.get_user_by_phone(phone).id == user.id
    end

    test "rejects a phone already linked to a different account, before sending a code" do
      other = user_fixture()
      user = email_user_fixture()

      assert {:error, :phone_taken} = Accounts.request_phone_link(user, other.phone)
      refute Accounts.get_user!(user.id).phone
    end

    test "allows re-requesting a link for the user's own already-linked phone" do
      user = user_fixture()
      assert {:ok, _phone} = Accounts.request_phone_link(user, user.phone)
    end

    test "confirm_phone_link rejects a wrong code and does not set the phone" do
      user = email_user_fixture()
      phone = unique_user_phone()
      {:ok, _} = Accounts.request_phone_link(user, phone)

      assert {:error, :invalid_or_expired} = Accounts.confirm_phone_link(user, phone, "000000")
      refute Accounts.get_user!(user.id).phone
    end

    test "a code issued for one account cannot be used to link the phone to a different account" do
      user_a = email_user_fixture()
      user_b = email_user_fixture()
      phone = unique_user_phone()

      {:ok, _} = Accounts.request_phone_link(user_a, phone)
      code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      assert {:error, :invalid_or_expired} = Accounts.confirm_phone_link(user_b, phone, code)
      refute Accounts.get_user!(user_b.id).phone
    end

    test "a login OTP code cannot confirm a phone link, and vice versa" do
      user = email_user_fixture()
      phone = unique_user_phone()

      {:ok, _} = Accounts.request_phone_link(user, phone)
      link_code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      {:ok, _, :whatsapp} = Accounts.request_otp(phone)
      login_code = NursePrep.Accounts.OtpSender.Test.last_code(phone)

      assert {:error, :invalid_or_expired} = Accounts.confirm_phone_link(user, phone, login_code)
      assert {:error, :invalid_or_expired} = Accounts.verify_otp(phone, link_code)
    end

    test "rate-limits repeated link requests for the same phone" do
      user = email_user_fixture()
      phone = unique_user_phone()

      assert {:ok, _} = Accounts.request_phone_link(user, phone)
      assert {:ok, _} = Accounts.request_phone_link(user, phone)
      assert {:ok, _} = Accounts.request_phone_link(user, phone)
      assert {:error, :rate_limited} = Accounts.request_phone_link(user, phone)
    end
  end

  describe "request_email_link/2 and confirm_email_link/3" do
    test "sends a code over email and links it to a phone-only account on confirmation" do
      user = user_fixture()
      email = unique_user_email()

      assert {:ok, ^email} = Accounts.request_email_link(user, email)
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:ok, updated_user} = Accounts.confirm_email_link(user, email, code)
      assert updated_user.id == user.id
      assert updated_user.email == email
      assert Accounts.get_user_by_email(email).id == user.id
    end

    test "rejects an email already linked to a different account, before sending a code" do
      other = email_user_fixture()
      user = user_fixture()

      assert {:error, :email_taken} = Accounts.request_email_link(user, other.email)
      refute Accounts.get_user!(user.id).email
    end

    test "allows re-requesting a link for the user's own already-linked email" do
      user = email_user_fixture()
      assert {:ok, _email} = Accounts.request_email_link(user, user.email)
    end

    test "confirm_email_link rejects a wrong code and does not set the email" do
      user = user_fixture()
      email = unique_user_email()
      {:ok, _} = Accounts.request_email_link(user, email)

      assert {:error, :invalid_or_expired} = Accounts.confirm_email_link(user, email, "000000")
      refute Accounts.get_user!(user.id).email
    end

    test "a code issued for one account cannot be used to link the email to a different account" do
      user_a = user_fixture()
      user_b = user_fixture()
      email = unique_user_email()

      {:ok, _} = Accounts.request_email_link(user_a, email)
      code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:error, :invalid_or_expired} = Accounts.confirm_email_link(user_b, email, code)
      refute Accounts.get_user!(user_b.id).email
    end

    test "a login OTP code cannot confirm an email link, and vice versa" do
      user = user_fixture()
      email = unique_user_email()

      {:ok, _} = Accounts.request_email_link(user, email)
      link_code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      {:ok, _, :email} = Accounts.request_email_otp(email)
      login_code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)

      assert {:error, :invalid_or_expired} = Accounts.confirm_email_link(user, email, login_code)
      assert {:error, :invalid_or_expired} = Accounts.verify_email_otp(email, link_code)
    end

    test "rate-limits repeated link requests for the same email" do
      user = user_fixture()
      email = unique_user_email()

      assert {:ok, _} = Accounts.request_email_link(user, email)
      assert {:ok, _} = Accounts.request_email_link(user, email)
      assert {:ok, _} = Accounts.request_email_link(user, email)
      assert {:error, :rate_limited} = Accounts.request_email_link(user, email)
    end
  end

  describe "get_user_by_whatsapp_lid/1 and link_whatsapp_lid/2" do
    test "does not return a user for an unlinked lid" do
      refute Accounts.get_user_by_whatsapp_lid("123456789@lid")
    end

    test "links a lid to a user, findable afterward" do
      user = user_fixture()
      lid = "123456789@lid"

      assert {:ok, linked} = Accounts.link_whatsapp_lid(user, lid)
      assert linked.whatsapp_lid == lid
      assert Accounts.get_user_by_whatsapp_lid(lid).id == user.id
    end

    test "rejects linking the same lid to two different users" do
      lid = "123456789@lid"
      {:ok, _} = Accounts.link_whatsapp_lid(user_fixture(), lid)

      assert {:error, changeset} = Accounts.link_whatsapp_lid(user_fixture(), lid)
      assert "has already been taken" in errors_on(changeset).whatsapp_lid
    end
  end

  describe "get_user_by_telegram_chat_id/1 and link_telegram_chat_id/2" do
    test "does not return a user for an unlinked chat id" do
      refute Accounts.get_user_by_telegram_chat_id(123_456_789)
    end

    test "links a chat id to a user, findable afterward" do
      user = user_fixture()

      assert {:ok, linked} = Accounts.link_telegram_chat_id(user, 123_456_789)
      assert linked.telegram_chat_id == 123_456_789
      assert Accounts.get_user_by_telegram_chat_id(123_456_789).id == user.id
    end

    test "rejects linking the same chat id to two different users" do
      {:ok, _} = Accounts.link_telegram_chat_id(user_fixture(), 123_456_789)

      assert {:error, changeset} = Accounts.link_telegram_chat_id(user_fixture(), 123_456_789)
      assert "has already been taken" in errors_on(changeset).telegram_chat_id
    end
  end

  describe "unlink_telegram_chat_id/1" do
    test "clears the chat id, freeing it up to be linked elsewhere" do
      user = user_fixture()
      {:ok, user} = Accounts.link_telegram_chat_id(user, 123_456_789)

      assert {:ok, unlinked} = Accounts.unlink_telegram_chat_id(user)
      refute unlinked.telegram_chat_id
      refute Accounts.get_user_by_telegram_chat_id(123_456_789)

      # The whole point: the freed-up chat id can now go to someone else.
      assert {:ok, _} = Accounts.link_telegram_chat_id(user_fixture(), 123_456_789)
    end

    test "is a no-op (not a validation error) for a user with nothing linked" do
      user = user_fixture()
      assert {:ok, unlinked} = Accounts.unlink_telegram_chat_id(user)
      refute unlinked.telegram_chat_id
    end
  end

  describe "User.identifier/1" do
    test "prefers phone, falling back to email" do
      assert User.identifier(%User{phone: "+2348011111111", email: "a@example.com"}) ==
               "+2348011111111"

      assert User.identifier(%User{phone: nil, email: "a@example.com"}) == "a@example.com"
    end
  end

  describe "list_daily_quiz_opt_in_users/0" do
    test "excludes a phone-less (email-only), Telegram-unlinked user even if profile opt-in is set" do
      phone_user = user_fixture()

      {:ok, _} =
        Accounts.create_profile(phone_user.id, %{
          "full_name" => "Phone User",
          "whatsapp_opt_in" => true
        })

      email_user = email_user_fixture()

      {:ok, _} =
        Accounts.create_profile(email_user.id, %{
          "full_name" => "Email User",
          "whatsapp_opt_in" => true
        })

      ids = Accounts.list_daily_quiz_opt_in_users() |> Enum.map(& &1.id)
      assert phone_user.id in ids
      refute email_user.id in ids
    end

    test "includes a phone-less (email-only) user who has linked Telegram" do
      email_user = email_user_fixture()
      {:ok, email_user} = Accounts.link_telegram_chat_id(email_user, 123_456_789)

      {:ok, _} =
        Accounts.create_profile(email_user.id, %{
          "full_name" => "Telegram-only User",
          "whatsapp_opt_in" => true
        })

      ids = Accounts.list_daily_quiz_opt_in_users() |> Enum.map(& &1.id)
      assert email_user.id in ids
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -11, :minute)}, -10)
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "generate_user_session_token/1" do
    test "generates a token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil
    end
  end

  describe "get_user_by_session_token/1" do
    test "returns user by token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert {session_user, _inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      dt = ~N[2020-01-01 00:00:00]
      Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "promote_to_role/2 and admin?/1" do
    test "promotes a user and admin?/1 reflects it" do
      user = user_fixture()
      refute Accounts.admin?(user)

      assert {:ok, admin} = Accounts.promote_to_role(user, "admin")
      assert admin.role == "admin"
      assert Accounts.admin?(admin)
    end

    test "rejects an unknown role" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.promote_to_role(user, "superuser")
      assert "is invalid" in errors_on(changeset).role
    end
  end

  describe "update_user_phone/2 and update_user_email/2" do
    test "sets the phone with no OTP required" do
      user = email_user_fixture()
      new_phone = unique_user_phone()

      assert {:ok, updated} = Accounts.update_user_phone(user, new_phone)
      assert updated.phone == new_phone
    end

    test "rejects a phone already belonging to a different user" do
      other = user_fixture()
      user = email_user_fixture()

      assert {:error, changeset} = Accounts.update_user_phone(user, other.phone)
      assert "has already been taken" in errors_on(changeset).phone
    end

    test "sets the email with no OTP required" do
      user = user_fixture()
      new_email = unique_user_email()

      assert {:ok, updated} = Accounts.update_user_email(user, new_email)
      assert updated.email == new_email
    end

    test "rejects an email already belonging to a different user" do
      other = email_user_fixture()
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_user_email(user, other.email)
      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "delete_user/1" do
    test "deletes the user and cascades to their profile and subscription" do
      user = user_fixture()
      profile = insert(:profile_for, user: user, full_name: "Ada Nurse")
      subscription = insert(:subscription, user: user)

      assert {:ok, _} = Accounts.delete_user(user)

      refute Repo.get(User, user.id)
      refute Repo.get(NursePrep.Accounts.Profile, profile.id)
      refute Repo.get(NursePrep.Subscriptions.Subscription, subscription.id)
    end

    test "deletes the user's whatsapp_session, which isn't a foreign key" do
      user = user_fixture()

      {:ok, whatsapp_session} =
        %NursePrep.Whatsapp.WhatsappSession{}
        |> NursePrep.Whatsapp.WhatsappSession.changeset(%{
          "phone" => user.phone,
          "expires_at" =>
            DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      assert {:ok, _} = Accounts.delete_user(user)

      refute Repo.get(NursePrep.Whatsapp.WhatsappSession, whatsapp_session.id)
    end
  end

  describe "profiles" do
    test "create_profile/2 then update_profile/2 round-trip" do
      user = user_fixture()

      assert {:ok, profile} =
               Accounts.create_profile(user.id, %{"full_name" => "Ada Nurse"})

      assert profile.full_name == "Ada Nurse"

      assert {:ok, updated} =
               Accounts.update_profile(profile, %{"school" => "UNILAG School of Nursing"})

      assert updated.school == "UNILAG School of Nursing"
    end
  end

  describe "count_students/0" do
    test "counts only role: student accounts" do
      before_count = Accounts.count_students()

      user_fixture()
      user_fixture()
      admin = admin_fixture()
      {:ok, _reviewer} = Accounts.promote_to_role(user_fixture(), "reviewer")

      assert Accounts.count_students() == before_count + 2
      refute admin.role == "student"
    end
  end

  describe "list_recent_signups/1" do
    test "returns students newest first, respecting the limit" do
      _oldest = user_fixture()
      middle = user_fixture()
      newer = user_fixture()

      assert Accounts.list_recent_signups(2) |> Enum.map(& &1.id) == [newer.id, middle.id]
    end

    test "excludes admin and reviewer accounts" do
      admin = admin_fixture()
      reviewer = user_fixture()
      {:ok, reviewer} = Accounts.promote_to_role(reviewer, "reviewer")
      student = user_fixture()

      ids = Accounts.list_recent_signups() |> Enum.map(& &1.id)

      assert student.id in ids
      refute admin.id in ids
      refute reviewer.id in ids
    end
  end
end
