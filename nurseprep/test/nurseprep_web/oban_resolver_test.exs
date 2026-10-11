defmodule NursePrepWeb.ObanResolverTest do
  @moduledoc """
  Regression coverage for a gap found in the Milestone 10 authorization
  audit: Oban Web job args carry PII/financial data (Paystack payloads,
  phone numbers, AI tutor message content) with no per-field redaction
  hook, so a `reviewer`-explicitly denied `Admin.UserLive` and
  `Admin.SubscriptionLive` for exactly that reason-must not get in
  through this back door either.
  """
  use NursePrep.DataCase, async: true

  import NursePrep.AccountsFixtures

  alias NursePrepWeb.ObanResolver

  test "admin gets full access" do
    admin = admin_fixture()
    assert ObanResolver.resolve_access(admin) == :all
  end

  test "reviewer is forbidden" do
    reviewer = user_fixture()
    {:ok, reviewer} = NursePrep.Accounts.promote_to_role(reviewer, "reviewer")

    assert ObanResolver.resolve_access(reviewer) == {:forbidden, "/"}
  end

  test "a plain student is forbidden" do
    student = user_fixture()
    assert ObanResolver.resolve_access(student) == {:forbidden, "/"}
  end

  test "no user (nil) is forbidden" do
    assert ObanResolver.resolve_access(nil) == {:forbidden, "/"}
  end
end
