import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :nurseprep, NursePrep.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "nurseprep_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nurseprep, NursePrepWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "AosWJHPDAH0bZYZngkTVfSlkmx26tDewYR9TcfXYOfqBOg2D3hqyzmR+uOAqJ3KA",
  server: false

config :nurseprep, Oban, testing: :manual
config :nurseprep, NursePrep.Mailer, adapter: Swoosh.Adapters.Test
config :nurseprep, :otp_sender, NursePrep.Accounts.OtpSender.Test
config :nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Test
config :nurseprep, :ingestion_docx_path, "test/fixtures/sample_questions.docx"
config :nurseprep, :evolution_client, NursePrep.Whatsapp.EvolutionClientMock
config :nurseprep, :telegram_client, NursePrep.Telegram.TelegramClientMock
config :nurseprep, :local_claude_client, NursePrep.Questions.LocalClaudeClientMock
config :nurseprep, :whatsapp_alert_sender, NursePrep.Whatsapp.AlertSender.Test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
