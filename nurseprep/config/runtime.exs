import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/nurseprep start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :nurseprep, NursePrepWeb.Endpoint, server: true
end

config :nurseprep, NursePrepWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# External service configuration. All three integrations are built against their
# documented HTTP contracts with no real credentials required to boot or run tests —
# real values drop in here later via env vars with zero code changes.
config :nurseprep, :evolution_api,
  base_url: System.get_env("EVOLUTION_API_BASE_URL"),
  instance: System.get_env("EVOLUTION_API_INSTANCE"),
  api_key: System.get_env("EVOLUTION_API_KEY"),
  webhook_token: System.get_env("EVOLUTION_WEBHOOK_TOKEN")

# Telegram fallback channel (see NursePrep.Messaging, Telegram.TelegramClient) -
# an official Bot API, unlike Evolution's unofficial WhatsApp bridge, so no
# self-hosted gateway/DB is needed here, just a bot token from @BotFather and
# a webhook secret Telegram delivers natively via the
# X-Telegram-Bot-Api-Secret-Token header (see TelegramWebhookController).
config :nurseprep, :telegram_api,
  bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
  bot_username: System.get_env("TELEGRAM_BOT_USERNAME")

# Login OTPs go out over WhatsApp automatically as soon as real Evolution
# credentials exist-no separate flag to flip at deploy time. Falls back
# to logging the code (config/dev.exs's default) when they don't.
if System.get_env("EVOLUTION_API_BASE_URL") do
  config :nurseprep, :otp_sender, NursePrep.Accounts.OtpSender.Evolution
end

# Email OTPs (the path for students without WhatsApp) go out over a real
# provider as soon as credentials exist. Brevo's API key (BREVO_API_KEY) is
# preferred over its SMTP relay-Brevo's SMTP auth rejected valid-looking
# credentials in practice (port 587 reachable, TLS fine, AUTH itself
# failing regardless of username/IP), while the API key worked immediately.
# SMTP_HOST is kept as a fallback for any other/future provider, since SMTP
# is universal (Gmail, SES, Mailgun, Postmark, Resend, ...) and this way
# there's no vendor lock-in baked into the app. Falls back to the dev
# mailbox / test capture (above) when neither is set.
cond do
  System.get_env("BREVO_API_KEY") ->
    config :nurseprep, NursePrep.Mailer,
      adapter: Swoosh.Adapters.Brevo,
      api_key: System.get_env("BREVO_API_KEY")

    config :nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Mailer

  System.get_env("SMTP_HOST") ->
    config :nurseprep, NursePrep.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: System.get_env("SMTP_HOST"),
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      tls: :always,
      auth: :always,
      retries: 2

    config :nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Mailer

  true ->
    :ok
end

config :nurseprep,
       :mailer_from_email,
       System.get_env("BREVO_SENDER_EMAIL") ||
         System.get_env("MAILER_FROM_EMAIL", "no-reply@nurseprep.ng")

# Where `NursePrep.Whatsapp.ConnectionAlert` emails when the paired WhatsApp
# session drops (see its moduledoc). Left unset in dev-alerts are logged
# either way (`AlertSender.Log`, the default); this switches on the real
# email (`AlertSender.Mailer`) only once an inbox is configured for prod.
config :nurseprep, :whatsapp_alert_email, System.get_env("WHATSAPP_ALERT_EMAIL")

if System.get_env("WHATSAPP_ALERT_EMAIL") do
  config :nurseprep, :whatsapp_alert_sender, NursePrep.Whatsapp.AlertSender.Mailer
end

config :nurseprep, :paystack,
  secret_key: System.get_env("PAYSTACK_SECRET_KEY"),
  public_key: System.get_env("PAYSTACK_PUBLIC_KEY")

config :nurseprep, :xai,
  api_key: System.get_env("X_API_KEY"),
  model: System.get_env("XAI_MODEL", "grok-4")

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :nurseprep, NursePrepWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/nurseprep_web/router\.ex$",
        ~r"lib/nurseprep_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :nurseprep, NursePrep.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :nurseprep, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :nurseprep, NursePrepWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :nurseprep, NursePrepWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :nurseprep, NursePrepWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
