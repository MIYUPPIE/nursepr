# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :nurseprep, :scopes,
  user: [
    default: true,
    module: NursePrep.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: NursePrep.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :nurseprep,
  namespace: NursePrep,
  ecto_repos: [NursePrep.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Read at boot by NursePrep.Application to skip work that only makes sense
  # outside test (e.g. ConnectionAlert.sync_from_evolution/0, which would
  # otherwise race Mox.defmock in test_helper.exs since Mix starts the OTP
  # app before requiring that file).
  env: config_env()

# Configure the endpoint
config :nurseprep, NursePrepWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NursePrepWeb.ErrorHTML, json: NursePrepWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: NursePrep.PubSub,
  live_view: [signing_salt: "m1zxwGIO"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  nurseprep: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  nurseprep: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Swoosh.Adapters.Brevo (config/runtime.exs, prod) needs a real HTTP client-
# Req is already a direct dependency (see EvolutionClient), so reuse it
# rather than pulling in Hackney just for this.
config :swoosh, :api_client, Swoosh.ApiClient.Req

config :nurseprep, :exam_format, question_count: 100, time_limit_minutes: 90

config :nurseprep, :practice_question_count, 10
# ₦3,000/month, indicative per the founder's proposal-easily tunable.
config :nurseprep, :subscription_amount_kobo, 300_000
config :nurseprep, :free_daily_practice_limit, 10

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000]}

config :nurseprep, Oban,
  engine: Oban.Engines.Basic,
  repo: NursePrep.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", NursePrep.Quizzes.Workers.AutoSubmitExpiredExamWorker},
       # 07:00 WAT (Africa/Lagos, UTC+1)-a gentle morning nudge, not the middle of the night.
       {"0 6 * * *", NursePrep.Whatsapp.Workers.DailyQuizDropWorker},
       {"0 * * * *", NursePrep.Whatsapp.Workers.SessionCleanupWorker},
       # Self-heals `ConnectionAlert.connected?/0` if a `connection.update`
       # webhook ever gets missed mid-outage-see the worker's moduledoc.
       {"*/5 * * * *", NursePrep.Whatsapp.Workers.ConnectionSyncWorker}
     ]}
  ],
  queues: [
    default: 10,
    whatsapp: 20,
    ai_tutor: 5,
    ingestion: 1,
    payments: 10,
    exams: 5
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
