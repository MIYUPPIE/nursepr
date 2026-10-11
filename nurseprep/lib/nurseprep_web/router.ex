defmodule NursePrepWeb.Router do
  use NursePrepWeb, :router

  import NursePrepWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NursePrepWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NursePrepWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/webhooks", NursePrepWeb do
    pipe_through :api

    post "/evolution/:token", WhatsappWebhookController, :receive
    # Confirmed against evoapicloud/evolution-api v2.3.1 (the exact image
    # this app runs-see evolution/docker-compose.yml): Evolution appends a
    # per-event suffix to the configured webhook URL regardless of the
    # `byEvents` instance setting, e.g. POST .../evolution/<token>//messages-upsert.
    # Without this route those deliveries 404 and get silently dropped.
    post "/evolution/:token/*event_suffix", WhatsappWebhookController, :receive
    post "/paystack", PaystackWebhookController, :receive
    # No suffix-wildcard route needed here, unlike Evolution's above:
    # Telegram delivers to exactly the URL registered via `setWebhook`.
    post "/telegram", TelegramWebhookController, :receive
  end

  # Other scopes may use custom stacks.
  # scope "/api", NursePrepWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:nurseprep, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NursePrepWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", NursePrepWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/subscription/callback", SubscriptionCallbackController, :show

    live_session :require_authenticated_user,
      on_mount: [{NursePrepWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/dashboard", DashboardLive, :index
      live "/practice", PracticeLive.Show, :new
      live "/practice/:session_id", PracticeLive.Show, :show
      live "/exam/new", ExamLive.Show, :new
      live "/exam/:session_id", ExamLive.Show, :show
      live "/sessions/:session_id/results", ResultsLive, :show
      live "/analytics", AnalyticsLive, :show
      live "/leaderboard", LeaderboardLive, :show
      live "/subscription", SubscriptionLive, :show
      live "/tutor", AiTutorLive, :show
    end
  end

  scope "/", NursePrepWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{NursePrepWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Admin routes-full dashboard lands as the Questions/Analytics
  ## milestones ship; the route gate itself is real from Milestone 1 on.

  scope "/admin", NursePrepWeb.Admin, as: :admin do
    pipe_through [:browser, :require_authenticated_user]

    live_session :admin,
      on_mount: [
        {NursePrepWeb.UserAuth, :require_authenticated},
        {NursePrepWeb.UserAuth, :require_admin}
      ] do
      live "/", DashboardLive, :index
      live "/review-queue", ReviewQueueLive, :index
      live "/questions", QuestionLive.Index, :index
      live "/questions/new", QuestionLive.New, :new
      live "/questions/:id", QuestionLive.Show, :show
      live "/subjects", SubjectLive.Index, :index
      live "/ingestion", IngestionLive, :index
    end

    # Stricter than :admin above-a `reviewer` (content-only role) is
    # denied these; they touch PII/financial data reviewers have no
    # business seeing.
    live_session :admin_strict,
      on_mount: [
        {NursePrepWeb.UserAuth, :require_authenticated},
        {NursePrepWeb.UserAuth, :require_admin},
        {NursePrepWeb.UserAuth, :require_strict_admin}
      ] do
      live "/users", UserLive.Index, :index
      live "/subscriptions", SubscriptionLive.Index, :index
    end
  end

  import Oban.Web.Router

  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user]
    oban_dashboard("/oban", resolver: NursePrepWeb.ObanResolver)
  end
end
