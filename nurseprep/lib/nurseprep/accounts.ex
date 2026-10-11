defmodule NursePrep.Accounts do
  @moduledoc """
  The Accounts context: phone+OTP authentication over WhatsApp for most
  students, with email+OTP as the fallback for the students who don't have
  WhatsApp (no passwords either way). Telegram, once a student links it, is
  preferred over both when reachable-see `request_otp/1` and
  `request_email_otp/1`. `OtpSender.Log` / `EmailOtpSender.Log` stand in for
  real delivery locally; roles and student profiles live here too.
  """

  import Ecto.Query, warn: false
  require Logger
  alias NursePrep.Repo

  alias NursePrep.Accounts.{User, UserToken, Profile, OtpSender, EmailOtpSender, PhoneNumber}
  alias NursePrep.Accounts.Email, as: EmailAddress
  alias NursePrep.Messaging
  alias NursePrep.Whatsapp.ConnectionAlert

  @otp_request_limit {60_000 * 10, 3}
  @otp_verify_limit {60_000 * 10, 5}
  @phone_link_context "phone_link"
  @email_link_context "email_link"
  @telegram_link_context "telegram_link"
  @telegram_link_login_context "telegram_link_login"

  ## Database getters

  def get_user_by_phone(phone) when is_binary(phone), do: Repo.get_by(User, phone: phone)

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  def get_user_by_whatsapp_lid(lid) when is_binary(lid), do: Repo.get_by(User, whatsapp_lid: lid)

  def get_user_by_telegram_chat_id(chat_id) when is_integer(chat_id),
    do: Repo.get_by(User, telegram_chat_id: chat_id)

  def get_user!(id), do: Repo.get!(User, id)

  def list_users(filters \\ %{}) do
    User
    |> apply_filters(filters)
    |> order_by([u], desc: u.inserted_at)
    |> preload(:profile)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:role, role}, q ->
        where(q, [u], u.role == ^role)

      {:search, term}, q ->
        where(q, [u], ilike(u.phone, ^"%#{term}%") or ilike(u.email, ^"%#{term}%"))

      _, q ->
        q
    end)
  end

  @doc "Count of `student`-role accounts-the admin dashboard's customer-facing headline number (excludes admin/reviewer staff accounts)."
  def count_students, do: Repo.aggregate(from(u in User, where: u.role == "student"), :count)

  @doc """
  Most recently created student accounts, newest first-the admin
  dashboard's activity feed. Scoped to `role: "student"`-an admin or
  reviewer account being provisioned is an infrequent staffing operation,
  not the customer-signup activity this feed exists to surface, and
  mixing the two in would bury real signups under staff noise. Ordered by
  `inserted_at, id` (both descending)-`inserted_at` alone is
  second-precision, so two signups in the same second (plausible under
  real traffic, routine in tests) would otherwise tie and sort
  unpredictably.
  """
  def list_recent_signups(limit \\ 5) do
    User
    |> where([u], u.role == "student")
    |> order_by([u], desc: u.inserted_at, desc: u.id)
    |> limit(^limit)
    |> preload(:profile)
    |> Repo.all()
  end

  @doc """
  Confirmed users who've opted in to the daily quiz drop-over WhatsApp,
  Telegram, or whichever of the two is actually reachable for them
  (`DailyQuizDropWorker` picks per-user, since `ConnectionAlert.connected?/0`
  is a single global flag, not per-student). Requires *some* bot channel
  (phone or a linked Telegram id); `whatsapp_opt_in` is the one opt-in flag
  for both-it predates Telegram but is really "opted into proactive bot
  messaging," not something WhatsApp-specific to rename a live column over.
  """
  def list_daily_quiz_opt_in_users do
    User
    |> join(:inner, [u], p in Profile, on: p.user_id == u.id)
    |> where(
      [u, p],
      not is_nil(u.confirmed_at) and
        (not is_nil(u.phone) or not is_nil(u.telegram_chat_id)) and
        p.whatsapp_opt_in == true
    )
    |> Repo.all()
  end

  ## OTP request / verification

  @doc """
  Requests an OTP for `phone`: normalizes the number, finds-or-creates the
  user, generates and stores a hashed code, and delivers the plaintext
  code. Rate-limited per phone number to keep a 6-digit code from being
  brute-forceable through unlimited re-sends.

  Delivery channel: WhatsApp (the configured `OtpSender`) whenever
  `ConnectionAlert.connected?/0` says the paired session is up. When it's
  down, falls back to Telegram if this user already linked one
  (`telegram_chat_id`)-Telegram can't push to a chat id that's never
  messaged the bot, so this can never be a cold-start channel the way
  WhatsApp/email are. With neither available, returns one of two distinct
  errors so the login UI can point the student at whichever fallback
  actually reaches *their* account: `{:error, :whatsapp_unavailable}` when
  they have an email on file (the Email tab logs into this same account),
  or `{:error, :whatsapp_unavailable_no_fallback, telegram_link_token}`
  when they have neither email nor Telegram-the Email tab would silently
  create an unrelated account for a phone-only user typing in a fresh
  address there, so that case needs to point at linking Telegram instead.
  `telegram_link_token` is a one-tap token (see
  `request_telegram_link_token/1`) the login UI embeds in a
  `Messaging.telegram_deep_link/1` so tapping it links Telegram *and*
  fires this same login OTP with no phone/email typed by hand and no need
  to come back and re-submit the form.

  On success returns `{:ok, user, channel}` (`channel` is `:whatsapp` or
  `:telegram`)-not just `{:ok, user}`-so the caller can tell the student
  which app to go check rather than always saying "check WhatsApp" even on
  a Telegram-delivered code.
  """
  def request_otp(phone) do
    with {:ok, normalized} <- PhoneNumber.normalize(phone),
         {:allow, _count} <- check_rate(:otp_request, normalized, @otp_request_limit) do
      user = get_user_by_phone(normalized) || insert_user_by_phone!(normalized)
      deliver_phone_otp(user, normalized)
    else
      {:deny, _limit} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_phone_otp(user, normalized_phone) do
    cond do
      ConnectionAlert.connected?() ->
        with {:ok, user} <-
               deliver_otp(user, normalized_phone, fn code ->
                 OtpSender.deliver(normalized_phone, code)
               end) do
          {:ok, user, :whatsapp}
        end

      user.telegram_chat_id ->
        with {:ok, user} <- send_telegram_login_otp(user) do
          {:ok, user, :telegram}
        end

      user.email ->
        {:error, :whatsapp_unavailable}

      true ->
        token = build_and_store_telegram_link_token(user, @telegram_link_login_context)
        {:error, :whatsapp_unavailable_no_fallback, token}
    end
  end

  @doc """
  Sends a fresh login OTP over Telegram for `user`, who must already have
  `telegram_chat_id` linked. Factored out of `deliver_phone_otp/2` so
  `Whatsapp.Session.confirm_telegram_link_start/2` can call the exact same
  path right after a `:login`-purpose `confirm_telegram_link_token/2`
  succeeds-tapping the deep link is enough to get a code, with no need to
  go back to the site and resubmit the login form.
  """
  def send_telegram_login_otp(%User{telegram_chat_id: chat_id, phone: phone} = user)
      when is_integer(chat_id) and is_binary(phone) do
    send_telegram_otp(user, phone)
  end

  @doc """
  Same as `send_telegram_login_otp/1`, for a user identified by `email`
  instead of `phone`-the cold-start Telegram login path (`Whatsapp.Session`)
  can land on either identifier depending on what the student typed into
  the bot, and `User.identifier/1` accounts can be email-primary with no
  phone at all.
  """
  def send_telegram_login_email_otp(%User{telegram_chat_id: chat_id, email: email} = user)
      when is_integer(chat_id) and is_binary(email) do
    send_telegram_otp(user, email)
  end

  # Shared by `send_telegram_login_otp/1` (phone path, `sent_to` is the
  # phone) and `deliver_email_otp/2` (email path, `sent_to` is the email)-
  # the only thing that differs between them is which field on `user` the
  # code needs to stay verifiable against.
  defp send_telegram_otp(%User{telegram_chat_id: chat_id} = user, sent_to)
       when is_integer(chat_id) and is_binary(sent_to) do
    identity = Messaging.tag_telegram(chat_id)
    deliver_otp(user, sent_to, fn code -> OtpSender.Telegram.deliver(identity, code) end)
  end

  @doc """
  Requests an OTP for `email`-the login path for students without
  WhatsApp. Same shape as `request_otp/1`: normalizes the address,
  finds-or-creates the user, and delivers the code.

  Delivery channel: Telegram whenever this user already has a
  `telegram_chat_id` linked, email otherwise. Unlike `request_otp/1`'s
  WhatsApp-down check, this isn't gated on any "is it up" signal-an
  email-primary account (no `phone` on file at all, see `User.identifier/1`)
  has no WhatsApp leg to be down *from*, so there's nothing to fall back
  past. Telegram is simply preferred outright once linked: it's push,
  near-instant, and exactly the channel the student chose to add-holding
  out for an inbox that might be slow, filtered, or never checked would be
  strictly worse for a student who already did the work of linking a
  faster one. Same `{:ok, user, channel}` shape as `request_otp/1` so the
  login UI can point at the right app.
  """
  def request_email_otp(email) do
    with {:ok, normalized} <- EmailAddress.normalize(email),
         {:allow, _count} <- check_rate(:otp_request, normalized, @otp_request_limit) do
      user = get_user_by_email(normalized) || insert_user_by_email!(normalized)
      deliver_email_otp(user, normalized)
    else
      {:deny, _limit} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_email_otp(%User{telegram_chat_id: chat_id} = user, normalized_email)
       when is_integer(chat_id) do
    with {:ok, user} <- send_telegram_otp(user, normalized_email) do
      {:ok, user, :telegram}
    end
  end

  defp deliver_email_otp(user, normalized_email) do
    with {:ok, user} <-
           deliver_otp(user, normalized_email, fn code ->
             EmailOtpSender.deliver(normalized_email, code)
           end) do
      {:ok, user, :email}
    end
  end

  # `sent_to` is always the real phone/email-the value `UserToken`'s
  # `sent_to` column stores and `verify_otp/2`/`verify_email_otp/2` look
  # up by, since the login UI always re-submits whatever the student
  # originally typed there, never whatever channel actually delivered the
  # code. `deliver_fun` is a `code -> :ok | {:error, term()}` closure so
  # callers can capture a *different* actual send target (e.g. a tagged
  # Telegram identity) without that leaking into `sent_to` and making the
  # code unverifiable.
  defp deliver_otp(user, sent_to, deliver_fun, context \\ "otp") do
    {code, user_token} = UserToken.build_otp_token(user, sent_to, context)
    Repo.insert!(user_token)

    case deliver_fun.(code) do
      :ok ->
        {:ok, user}

      {:error, reason} ->
        Logger.error("[Accounts] OTP delivery to #{sent_to} failed: #{inspect(reason)}")
        {:error, :delivery_failed}
    end
  end

  @doc "Creates a new user identified by `normalized_phone`. Public so cold-start linking flows (e.g. `Whatsapp.Session`'s Telegram-first login) can find-or-create the same way `request_otp/1` does, without duplicating the changeset call."
  def insert_user_by_phone!(normalized_phone) do
    %User{} |> User.phone_changeset(%{"phone" => normalized_phone}) |> Repo.insert!()
  end

  @doc "Creates a new user identified by `normalized_email`. Same rationale as `insert_user_by_phone!/1`."
  def insert_user_by_email!(normalized_email) do
    %User{} |> User.email_changeset(%{"email" => normalized_email}) |> Repo.insert!()
  end

  @doc """
  Verifies an OTP code for `phone`. On success, confirms the user (first
  login), invalidates every outstanding OTP for that user, and returns a
  fresh session token. On failure, returns `{:error, :invalid_or_expired}` —
  deliberately vague so it doesn't disclose whether the phone is registered.
  """
  def verify_otp(phone, code) do
    case PhoneNumber.normalize(phone) do
      {:ok, normalized} -> do_verify_otp(normalized, code)
      {:error, _reason} -> {:error, :invalid_or_expired}
    end
  end

  @doc "Verifies an OTP code for `email`. Same contract as `verify_otp/2`."
  def verify_email_otp(email, code) do
    case EmailAddress.normalize(email) do
      {:ok, normalized} -> do_verify_otp(normalized, code)
      {:error, _reason} -> {:error, :invalid_or_expired}
    end
  end

  @doc """
  Sends a WhatsApp OTP to `phone` to verify ownership before linking it to
  `user`'s account-the path for a student who originally signed up with
  email (no WhatsApp) and now wants to add it. Confirm with
  `confirm_phone_link/3` once they reply with the code.

  Rejects with `{:error, :phone_taken}` up front if the number already
  belongs to a *different* account-linking must never silently reassign
  someone else's number, and this way that's caught before a code even
  goes out rather than after the student enters it. Rate-limited per phone,
  same as `request_otp/1`.
  """
  def request_phone_link(%User{} = user, phone) do
    with {:ok, normalized} <- PhoneNumber.normalize(phone),
         :ok <- check_phone_available(normalized, user),
         {:allow, _count} <- check_rate(:otp_request, normalized, @otp_request_limit) do
      case deliver_otp(
             user,
             normalized,
             fn code -> OtpSender.deliver(normalized, code) end,
             @phone_link_context
           ) do
        {:ok, _user} -> {:ok, normalized}
        {:error, reason} -> {:error, reason}
      end
    else
      {:deny, _limit} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_phone_available(phone, %User{id: user_id}) do
    case get_user_by_phone(phone) do
      nil -> :ok
      %User{id: ^user_id} -> :ok
      %User{} -> {:error, :phone_taken}
    end
  end

  @doc """
  Verifies the code sent by `request_phone_link/2` and, on success, sets
  `phone` on `user`'s account. Same vague-error contract as `verify_otp/2` —
  and additionally scoped to `user`'s own id, so a code issued for one
  account can never be replayed to attach that phone to a different one.
  """
  def confirm_phone_link(%User{id: user_id} = user, phone, code) do
    with {:ok, normalized} <- PhoneNumber.normalize(phone),
         {:allow, _count} <- check_rate(:otp_verify, normalized, @otp_verify_limit),
         {:ok, query} <- UserToken.verify_otp_token_query(normalized, code, @phone_link_context),
         {%User{id: ^user_id} = linked_user, _token} <- Repo.one(query) do
      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^user.id and t.context == @phone_link_context
      )

      linked_user |> User.phone_changeset(%{"phone" => normalized}) |> Repo.update()
    else
      {:deny, _limit} -> {:error, :rate_limited}
      _ -> {:error, :invalid_or_expired}
    end
  end

  @doc """
  Sends an OTP to `email` to verify ownership before linking it to `user`'s
  account-the path for a phone-only student (signed up over WhatsApp) who
  wants an email on file too, from the student dashboard. Same contract as
  `request_phone_link/2`: rejects with `{:error, :email_taken}` up front if
  the address already belongs to a *different* account, and is rate-limited
  per address.
  """
  def request_email_link(%User{} = user, email) do
    with {:ok, normalized} <- EmailAddress.normalize(email),
         :ok <- check_email_available(normalized, user),
         {:allow, _count} <- check_rate(:otp_request, normalized, @otp_request_limit) do
      case deliver_otp(
             user,
             normalized,
             fn code -> EmailOtpSender.deliver(normalized, code) end,
             @email_link_context
           ) do
        {:ok, _user} -> {:ok, normalized}
        {:error, reason} -> {:error, reason}
      end
    else
      {:deny, _limit} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_email_available(email, %User{id: user_id}) do
    case get_user_by_email(email) do
      nil -> :ok
      %User{id: ^user_id} -> :ok
      %User{} -> {:error, :email_taken}
    end
  end

  @doc """
  Verifies the code sent by `request_email_link/2` and, on success, sets
  `email` on `user`'s account. Same vague-error contract and own-account
  scoping as `confirm_phone_link/3`.
  """
  def confirm_email_link(%User{id: user_id} = user, email, code) do
    with {:ok, normalized} <- EmailAddress.normalize(email),
         {:allow, _count} <- check_rate(:otp_verify, normalized, @otp_verify_limit),
         {:ok, query} <- UserToken.verify_otp_token_query(normalized, code, @email_link_context),
         {%User{id: ^user_id} = linked_user, _token} <- Repo.one(query) do
      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^user.id and t.context == @email_link_context
      )

      linked_user |> User.email_changeset(%{"email" => normalized}) |> Repo.update()
    else
      {:deny, _limit} -> {:error, :rate_limited}
      _ -> {:error, :invalid_or_expired}
    end
  end

  @doc """
  Links a WhatsApp `@lid` identity to `user`'s account-called by
  `NursePrep.Whatsapp.Session` once the student has confirmed it's really
  them by replying with their account's own phone number (see
  `route_lid_confirmation/2` there). Every message from that same `@lid`
  after this resolves straight to `user`, same as a normal
  `@s.whatsapp.net` contact.
  """
  def link_whatsapp_lid(%User{} = user, lid) when is_binary(lid) do
    user |> User.whatsapp_lid_changeset(%{"whatsapp_lid" => lid}) |> Repo.update()
  end

  @doc """
  Links a Telegram chat id to `user`'s account-called by
  `NursePrep.Whatsapp.Session` once the student has confirmed it's really
  them by replying with their account's phone number or email (see
  `route_telegram_confirmation/2` there). Every message from that chat id
  after this resolves straight to `user`.
  """
  def link_telegram_chat_id(%User{} = user, chat_id) when is_integer(chat_id) do
    user |> User.telegram_chat_id_changeset(%{"telegram_chat_id" => chat_id}) |> Repo.update()
  end

  @doc """
  Unlinks `user`'s Telegram chat id-the self-service escape hatch for
  `confirm_telegram_link_token/2`'s `{:error, :chat_already_linked}`
  case: a Telegram account can only ever be linked to one NursePrep
  account at a time (`telegram_chat_id`'s unique constraint), so freeing
  it up here is the only way to move it to a different account. Doesn't
  touch anything else on the account, and doesn't require re-verifying
  WhatsApp/email first-Settings already requires the student to be
  logged in, which is proof enough for un-linking a *bot* channel (unlike
  linking, this can't be used to take over someone else's account).
  """
  def unlink_telegram_chat_id(%User{} = user) do
    # Not `telegram_chat_id_changeset/2`-its `validate_required` exists for
    # the *linking* direction (an empty value would mean "link to
    # nothing", a no-op that should never silently succeed) and would
    # reject clearing the field back to nil here.
    user |> Ecto.Changeset.change(telegram_chat_id: nil) |> Repo.update()
  end

  @doc """
  Issues a one-tap Telegram-linking token for `user`, to embed in a
  `Messaging.telegram_deep_link/1` from the Settings page-tapping Start on
  that link sends the token straight to the bot, which links the account
  immediately via `confirm_telegram_link_token/2` with no phone/email
  typed by hand. Unlike the token `deliver_phone_otp/2` issues on the
  WhatsApp-down login path (`"telegram_link_login"` context), confirming
  one of these doesn't fire a login OTP-the student requesting it from
  Settings is already logged in.
  """
  def request_telegram_link_token(%User{} = user) do
    build_and_store_telegram_link_token(user, @telegram_link_context)
  end

  defp build_and_store_telegram_link_token(user, context) do
    # Drop any earlier unconsumed token of the same purpose first, so a
    # student who requests a fresh link (or retries after the first one
    # expired) only ever has the one most-recent link actually work.
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == ^context)

    {token, user_token} =
      UserToken.build_telegram_link_token(user, User.identifier(user), context)

    Repo.insert!(user_token)
    token
  end

  @doc """
  The PubSub topic a login-page LiveView subscribes to right when it shows
  the "link Telegram" nudge (see `deliver_phone_otp/2`'s no-fallback
  branch), so it can jump straight to the code-entry step the instant
  `Whatsapp.Session.confirm_telegram_link_start/2` finishes linking and
  sending the code-tapping Start happens in the Telegram app, a
  completely different process from the browser tab that's waiting, so
  nothing about a plain page reload would ever pick that up. Keyed by the
  token itself (unguessable, single-use, and already the one piece of
  data both sides independently have) rather than the phone/email, so
  there's no risk of a topic collision between two different login
  attempts for the same identifier.
  """
  @spec telegram_link_topic(String.t()) :: String.t()
  def telegram_link_topic(token) when is_binary(token), do: "telegram_link:" <> token

  @cold_telegram_login_prefix "cold:"

  @doc """
  A one-shot opaque token for the login page's Telegram tab-unlike
  `request_telegram_link_token/1`, this is minted with no `%User{}` on hand
  yet (the whole point of the login page's Telegram option is that nobody's
  identified themselves there), so it's a bare random string rather than a
  `UserToken` row: nothing sensitive hangs off it before the student types
  their phone/email into the bot, and `telegram_link_topic/1` already gives
  it a PubSub channel to report back on once `Whatsapp.Session` resolves or
  creates the account. Prefixed so `Whatsapp.Session` can tell it apart
  from a real `UserToken`-backed link token in the same `/start <token>`
  slot without a database round-trip.
  """
  @spec build_cold_telegram_login_token() :: String.t()
  def build_cold_telegram_login_token do
    @cold_telegram_login_prefix <>
      (24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc "True for a token minted by `build_cold_telegram_login_token/0`."
  @spec cold_telegram_login_token?(String.t()) :: boolean()
  def cold_telegram_login_token?(token) when is_binary(token),
    do: String.starts_with?(token, @cold_telegram_login_prefix)

  @doc """
  Verifies the token from a `t.me/<bot>?start=<token>` deep link (see
  `request_telegram_link_token/1` and `deliver_phone_otp/2`) and, on
  success, links `chat_id` to whichever account it was issued for.

  Returns `{:ok, user, :login}` when the token came from the WhatsApp-down
  login nudge, or `{:ok, user, :settings}` when it came from a logged-in
  student proactively linking from Settings. Purely the link step-doesn't
  itself send a login OTP for the `:login` case, so the caller (see
  `Whatsapp.Session.confirm_telegram_link_start/2`) controls message
  order: confirm the link landed *before* `send_telegram_login_otp/1`
  drops a 6-digit code with no context into the same chat.

  `{:error, :chat_already_linked}` is the one *named* failure (versus the
  vague `:invalid_or_expired` the other confirm functions use)-worth
  telling apart from a stale/reused token because the fix is completely
  different: this `chat_id` (the sender, not the token's target account)
  is already linked to some *other* NursePrep account, so no fresh token
  would ever help. That's a real, reachable case: the same Telegram
  account already linked to account A tapping a deep link issued for
  account B-see the comment on `Whatsapp.Session.telegram_link_start/2`
  for why this can't just be prevented by declining to route the message.
  """
  def confirm_telegram_link_token(token, chat_id) when is_integer(chat_id) do
    with {:ok, query} <- UserToken.verify_telegram_link_token_query(token),
         {user, token_row} <- Repo.one(query) do
      Repo.delete_all(
        from t in UserToken,
          where:
            t.user_id == ^user.id and
              t.context in [^@telegram_link_context, ^@telegram_link_login_context]
      )

      purpose = if token_row.context == @telegram_link_login_context, do: :login, else: :settings

      case link_telegram_chat_id(user, chat_id) do
        {:ok, linked_user} ->
          {:ok, linked_user, purpose}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :telegram_chat_id) do
            {:error, :chat_already_linked}
          else
            {:error, changeset}
          end
      end
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  defp do_verify_otp(identifier, code) do
    with {:allow, _count} <- check_rate(:otp_verify, identifier, @otp_verify_limit),
         {:ok, query} <- UserToken.verify_otp_token_query(identifier, code),
         {user, _token} <- Repo.one(query) do
      user = maybe_confirm(user)
      Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == "otp")
      session_token = generate_user_session_token(user)
      {:ok, {user, session_token}}
    else
      {:deny, _limit} -> {:error, :rate_limited}
      _ -> {:error, :invalid_or_expired}
    end
  end

  defp maybe_confirm(%User{confirmed_at: nil} = user) do
    user |> User.confirm_changeset() |> Repo.update!()
  end

  defp maybe_confirm(user), do: user

  defp check_rate(kind, identifier, {scale_ms, limit}),
    do: Hammer.check_rate("#{kind}:#{identifier}", scale_ms, limit)

  ## Roles

  def promote_to_role(%User{} = user, role) do
    user |> User.role_changeset(%{"role" => role}) |> Repo.update()
  end

  def admin?(%User{role: role}), do: role in ["admin", "reviewer"]
  def admin?(_), do: false

  ## Admin-driven user management

  @doc """
  Admin-driven phone number change. Unlike `request_phone_link/2`, this
  writes straight through-no OTP/ownership proof-since it's already gated
  behind `:require_strict_admin` and the admin is trusted to have verified
  the number some other way (support ticket, ID check, etc.).
  """
  def update_user_phone(%User{} = user, phone) do
    user |> User.phone_changeset(%{"phone" => phone}) |> Repo.update()
  end

  @doc "Admin-driven email change. Same trust model as `update_user_phone/2`."
  def update_user_email(%User{} = user, email) do
    user |> User.email_changeset(%{"email" => email}) |> Repo.update()
  end

  @doc """
  Permanently deletes `user` and everything that belongs to them: profile,
  quiz history, subscriptions/payments, AI tutor conversations, and session
  tokens all cascade via `ON DELETE CASCADE` (see the `references(:users,
  on_delete: :delete_all)` migrations). Question reviews they made are
  preserved-`reviewed_by_user_id`/`reviewer_id` just go `nil`
  (`on_delete: :nilify_all`), since review history shouldn't vanish because
  a reviewer's account did.

  `whatsapp_sessions` isn't a foreign-key relationship (it's keyed by
  `phone`, not `user_id`-see its migration), so cascade alone doesn't reach
  it; deleted explicitly here in the same transaction so a deleted user's
  in-flight WhatsApp quiz state doesn't linger as an orphan.

  Irreversible - the caller (the admin UI) is responsible for confirming
  with the operator first.
  """
  def delete_user(%User{} = user) do
    Repo.transaction(fn ->
      if user.phone do
        Repo.delete_all(
          from w in NursePrep.Whatsapp.WhatsappSession, where: w.phone == ^user.phone
        )
      end

      case Repo.delete(user) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  ## Session

  @doc "Generates a session token."
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Deletes the signed token with the given context."
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Checks whether the user is in sudo mode (authenticated within the last
  `minutes`, default 20)-used to gate sensitive actions like role changes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  ## Profiles

  def get_profile(user_id), do: Repo.get_by(Profile, user_id: user_id)

  def create_profile(user_id, attrs) do
    %Profile{} |> Profile.changeset(Map.put(attrs, "user_id", user_id)) |> Repo.insert()
  end

  def update_profile(%Profile{} = profile, attrs) do
    profile |> Profile.changeset(attrs) |> Repo.update()
  end

  def change_profile(%Profile{} = profile, attrs \\ %{}) do
    Profile.changeset(profile, attrs)
  end
end
