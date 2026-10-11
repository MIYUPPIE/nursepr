defmodule NursePrep.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `NursePrep.Accounts` context.
  """

  import Ecto.Query

  alias NursePrep.Accounts
  alias NursePrep.Accounts.Scope

  @doc "A unique, valid Nigerian phone number in E.164 form."
  def unique_user_phone do
    # :monotonic keeps these small and strictly increasing within a test run,
    # so `rem(n, 10_000_000)` (the full 7-digit subscriber-number space) never
    # collides-a prior padding/slicing version of this dropped a digit of
    # entropy and caused rare cross-test collisions that fed spurious rate
    # limit hits into the (globally shared, not sandboxed) Hammer bucket.
    suffix =
      System.unique_integer([:positive, :monotonic])
      |> rem(10_000_000)
      |> Integer.to_string()
      |> String.pad_leading(7, "0")

    "+234803#{suffix}"
  end

  @doc "A unique, valid email address."
  def unique_user_email, do: "user#{System.unique_integer([:positive, :monotonic])}@example.com"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{phone: unique_user_phone()})
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)
    {:ok, user, _channel} = Accounts.request_otp(attrs.phone)
    user
  end

  @doc "A confirmed user, logged in via the real OTP flow."
  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)
    {:ok, _user, _channel} = Accounts.request_otp(attrs.phone)
    code = NursePrep.Accounts.OtpSender.Test.last_code(attrs.phone)
    {:ok, {user, _session_token}} = Accounts.verify_otp(attrs.phone, code)
    user
  end

  @doc """
  A confirmed user with no phone, logged in via the email+OTP flow-the
  path for students who don't have WhatsApp.
  """
  def email_user_fixture(attrs \\ %{}) do
    %{email: email} = Enum.into(attrs, %{email: unique_user_email()})
    {:ok, _user, :email} = Accounts.request_email_otp(email)
    code = NursePrep.Accounts.EmailOtpSender.Test.last_code(email)
    {:ok, {user, _session_token}} = Accounts.verify_email_otp(email, code)
    user
  end

  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, user} = Accounts.promote_to_role(user, "admin")
    user
  end

  def user_scope_fixture, do: user_fixture() |> user_scope_fixture()
  def user_scope_fixture(user), do: Scope.for_user(user)

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    NursePrep.Repo.update_all(
      from(t in Accounts.UserToken, where: t.token == ^token),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    NursePrep.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
