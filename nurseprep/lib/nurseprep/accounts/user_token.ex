defmodule NursePrep.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias NursePrep.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32
  @otp_code_digits 6
  @telegram_link_token_bytes 16

  # Generous compared to the OTP window-this token isn't a 6-digit code
  # typed by hand, it's ~128 bits of randomness embedded in a `t.me/...`
  # deep link (see `build_telegram_link_token/3`), so it isn't
  # meaningfully brute-forceable. 30 minutes is about giving someone time
  # to actually switch apps and tap it, not a security bound.
  @telegram_link_validity_in_minutes 30

  # Keep the OTP window short-it's a 6-digit code, not a long random magic
  # link token, so it's far more brute-forceable if left valid too long.
  @otp_validity_in_minutes 10

  # The session token doubles as the long-lived device token written to the
  # remember-me cookie on every successful OTP login (see
  # `NursePrepWeb.UserAuth.create_or_extend_session/3`)-once a device has
  # proven itself with an OTP code, it shouldn't need to prove it again for
  # 30-60 days, only when this expires, the student logs out, or they show
  # up on a device that never got the cookie. Must match
  # `NursePrepWeb.UserAuth`'s `@max_cookie_age_in_days`.
  @session_validity_in_days 45

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, NursePrep.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a 6-digit numeric OTP code and its hash, to be delivered to
  `sent_to`-a phone number over WhatsApp, or an email address for
  students without WhatsApp (or logged, in dev/test).

  The plaintext code is what gets sent to the user; only its hash is stored,
  so read-only DB access can't be used to log in as someone else. Binding the
  hash to `sent_to` (the identifier it was issued for) means a code issued
  before a phone/email change can never be replayed against the new value.

  `context` defaults to `"otp"` (login). A distinct context (e.g.
  `"phone_link"`, see `NursePrep.Accounts.request_phone_link/2`) keeps a
  verification code scoped to what it was actually issued for, so a code
  sent to prove phone ownership for linking can't also be replayed to log
  in as whichever account happens to already own that phone number.
  """
  def build_otp_token(user, sent_to, context \\ "otp") do
    code =
      1_000_000
      |> :rand.uniform()
      |> Kernel.-(1)
      |> Integer.to_string()
      |> String.pad_leading(@otp_code_digits, "0")

    hashed_token = :crypto.hash(@hash_algorithm, code)

    {code, %UserToken{token: hashed_token, context: context, sent_to: sent_to, user_id: user.id}}
  end

  @doc """
  Checks if the given plaintext OTP code is valid for `identifier` (a phone
  number or email address) in `context` (defaults to `"otp"`, see
  `build_otp_token/3`), returning its underlying lookup query. Valid means:
  matches the hashed value on file, issued for this exact identifier, and
  not older than #{@otp_validity_in_minutes} minutes.
  """
  def verify_otp_token_query(identifier, code, context \\ "otp") do
    hashed_token = :crypto.hash(@hash_algorithm, code)

    query =
      from token in by_token_and_context_query(hashed_token, context),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(^@otp_validity_in_minutes, "minute"),
        where: token.sent_to == ^identifier,
        select: {user, token}

    {:ok, query}
  end

  @doc """
  Builds a one-tap Telegram-linking token and its hash, for embedding in a
  `t.me/<bot>?start=<token>` deep link (see
  `NursePrep.Messaging.telegram_deep_link/1`)-tapping Telegram's
  auto-shown Start button sends this token straight back to the bot as
  `/start <token>`, letting `NursePrep.Accounts.confirm_telegram_link_token/2`
  link the account with no phone/email typed by hand.

  URL-safe base64 (`Base.url_encode64/2`, no padding) rather than the hex
  `build_otp_token/3` effectively uses: its alphabet (`A-Za-z0-9-_`) is
  exactly Telegram's allowed `start` parameter character set, and 16 bytes
  encodes to ~22 characters, comfortably under Telegram's 64-character cap.

  `context` distinguishes *why* the token was issued-`"telegram_link_login"`
  for the login page's WhatsApp-down nudge (which should fire a login OTP
  the moment the link is confirmed) versus `"telegram_link"` for a
  logged-in student proactively linking from Settings (which shouldn't).
  `verify_telegram_link_token_query/1` returns it back on the matched row
  so the caller can tell them apart.
  """
  def build_telegram_link_token(user, sent_to, context) do
    token =
      @telegram_link_token_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    hashed_token = :crypto.hash(@hash_algorithm, token)

    {token, %UserToken{token: hashed_token, context: context, sent_to: sent_to, user_id: user.id}}
  end

  @doc """
  Checks if the given plaintext Telegram-linking token (see
  `build_telegram_link_token/3`) is valid-matches the hashed value on
  file and not older than #{@telegram_link_validity_in_minutes} minutes-
  across both token purposes, returning its underlying lookup query. The
  selected token row's `context` tells the caller which purpose it was
  issued for.
  """
  def verify_telegram_link_token_query(token) do
    hashed_token = :crypto.hash(@hash_algorithm, token)

    query =
      from t in UserToken,
        where: t.token == ^hashed_token and t.context in ["telegram_link", "telegram_link_login"],
        join: user in assoc(t, :user),
        where: t.inserted_at > ago(^@telegram_link_validity_in_minutes, "minute"),
        select: {user, t}

    {:ok, query}
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
