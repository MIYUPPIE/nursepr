defmodule NursePrepWeb.PageController do
  use NursePrepWeb, :controller

  alias NursePrep.{Accounts, Analytics, Questions, Subscriptions}

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/dashboard")
    else
      render(conn, :home,
        question_count: Questions.count_published_questions(),
        student_count: Accounts.count_students(),
        amount_kobo: Subscriptions.plan_amount_kobo(),
        daily_limit: Subscriptions.free_daily_practice_limit(),
        leaderboard: Analytics.leaderboard(:weekly, 3)
      )
    end
  end
end
