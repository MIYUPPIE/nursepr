defmodule NursePrepWeb.ObanResolver do
  @moduledoc """
  Gates the Oban Web dashboard (`/admin/oban`) to `admin` users only-not
  `reviewer`. Job *args* are visible here (Oban Web has no per-field
  redaction hook), and several queues carry exactly the PII/financial data
  a reviewer is deliberately denied elsewhere (`Admin.UserLive`,
  `Admin.SubscriptionLive`): `payments` jobs carry Paystack payloads,
  `whatsapp`/`ai_tutor` jobs carry phone numbers and message content.
  Admin-only here keeps that boundary from having a back door.
  """
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_scope] && conn.assigns.current_scope.user

  @impl true
  def resolve_access(%{role: "admin"}), do: :all
  def resolve_access(_user), do: {:forbidden, "/"}
end
