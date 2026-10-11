defmodule NursePrepWeb.SubscriptionCallbackController do
  @moduledoc """
  Where Paystack redirects the browser back to after checkout
  (`callback_url` on `PaystackClient.initialize_transaction/3`). The
  webhook is the durable, always-correct path to entitlement-this
  controller is a synchronous, user-facing convenience on top of it:
  verify the transaction directly against Paystack right away so the user
  sees an accurate result immediately, rather than a stale "Free tier"
  page until the webhook happens to land.
  """
  use NursePrepWeb, :controller

  alias NursePrep.Subscriptions

  def show(conn, %{"reference" => reference}) do
    user = conn.assigns.current_scope.user

    case Subscriptions.confirm_payment(user, reference) do
      {:ok, _subscription} -> redirect_with(conn, :info, "Payment confirmed-you're on Premium!")
      :already_processed -> redirect_with(conn, :info, "Payment confirmed-you're on Premium!")
      {:error, :pending} -> redirect_with(conn, :info, pending_message())
      {:error, :failed} -> redirect_with(conn, :error, failed_message())
      {:error, :not_found} -> redirect_with(conn, :error, not_found_message())
    end
  end

  def show(conn, _params) do
    redirect_with(conn, :error, "Missing payment reference.")
  end

  defp pending_message,
    do:
      "We're still confirming your payment with Paystack-this usually takes a few seconds. Refresh shortly if it doesn't update."

  defp failed_message, do: "That payment didn't go through. Feel free to try again below."

  defp not_found_message,
    do:
      "We couldn't find that payment. If you were charged, contact support and we'll sort it out."

  defp redirect_with(conn, kind, message) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/subscription")
  end
end
