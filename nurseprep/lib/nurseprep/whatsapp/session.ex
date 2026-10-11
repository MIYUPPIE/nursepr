defmodule NursePrep.Whatsapp.Session do
  @moduledoc """
  One GenServer per active conversation, keyed by an opaque identity string
  in `Whatsapp.SessionRegistry` — a bare E.164 phone number or a WhatsApp
  `@lid` privacy id for a WhatsApp contact, or a `"telegram:<chat_id>"`
  tagged string for a Telegram one (see `NursePrep.Messaging`, which is
  the only place that cares which). Despite the module/table names (kept
  as-is rather than a risky rename of a live table + every call site),
  this is the shared engine for both channels — `MessageRouter` and every
  `dispatch/2` clause below are already channel-agnostic; only identity
  resolution and the outbound send delegate by identity shape. Postgres
  (`whatsapp_sessions`) is the durable source of truth; this process is a
  hot cache that rehydrates from it on init-so a node restart mid-quiz
  loses at most the in-memory speed, not the student's progress.

  Inactivity: after `@soft_timeout_ms` with no message, state is persisted
  and the process hibernates on its next receive rather than staying
  scheduled. After `@hard_expiry_seconds` total, the row is dropped and the
  process stops-a genuinely abandoned conversation shouldn't linger
  forever, in memory or in the database.
  """
  use GenServer
  require Logger

  alias NursePrep.{Accounts, Formatting, Messaging, Quizzes, Repo}
  alias NursePrep.Accounts.PhoneNumber
  alias NursePrep.Accounts.Email, as: EmailAddress
  alias NursePrep.Whatsapp.{MessageRouter, WhatsappSession}

  @soft_timeout_ms :timer.minutes(30)
  @hard_expiry_seconds 60 * 60 * 24

  # Evolution API (self-hosted, confirmed against this live instance's own
  # webhook log) redelivers a `messages.upsert` event for the same WhatsApp
  # message more than once-a retry with no change in content or message
  # id. Undetected, a redelivered answer letter gets submitted again,
  # silently advancing the quiz an extra question and firing a second
  # burst of replies for what was really one inbound message. A small
  # in-memory ring of recently-seen message ids is enough: retries land
  # within the same short window, not after a dozen other real messages.
  # Telegram's own `update_id` is passed through the same mechanism and
  # gets the same protection, though Telegram's webhook contract doesn't
  # redeliver the way Evolution's confirmed-buggy one does-this is
  # defense-in-depth there, not a fix for an observed problem.
  @max_recent_message_ids 20

  ## Public API

  def start_or_lookup(phone) do
    case Registry.lookup(NursePrep.Whatsapp.SessionRegistry, phone) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               NursePrep.Whatsapp.SessionSupervisor,
               {__MODULE__, phone}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc """
  Routes an inbound WhatsApp message to the session for `phone`, starting
  one if needed. `message_id` (Evolution's WhatsApp message id) is used to
  drop redelivered webhook events for the same message-pass it whenever
  it's known; omit it only for internally-synthesized messages that have
  no such id to dedupe against.
  """
  def handle_message(phone, text, message_id \\ nil) do
    {:ok, pid} = start_or_lookup(phone)
    GenServer.cast(pid, {:message, text, message_id})
  end

  @doc """
  Proactively sends `user_id` a one-question daily quiz over WhatsApp —
  triggered by `DailyQuizDropWorker`'s cron, never in response to an
  inbound message. Bypasses the free-tier daily practice limit (it's one
  question a day, meant to pull students back in, not something worth
  paywalling).
  """
  def send_daily_quiz(phone, user_id) do
    {:ok, pid} = start_or_lookup(phone)
    GenServer.cast(pid, {:daily_quiz, user_id})
  end

  @doc """
  Proactively tells `phone` that their timed exam ended — triggered by
  `AutoSubmitExpiredExamWorker`'s cron backstop when a student goes quiet
  mid-exam. Unlike the web app, WhatsApp has no client-side countdown to
  redirect them automatically, so without this push a student who steps
  away never finds out the exam is over.
  """
  def notify_exam_expired(phone, session_id) do
    {:ok, pid} = start_or_lookup(phone)
    GenServer.cast(pid, {:exam_expired, session_id})
  end

  def start_link(phone) do
    GenServer.start_link(__MODULE__, phone, name: via(phone))
  end

  defp via(phone), do: {:via, Registry, {NursePrep.Whatsapp.SessionRegistry, phone}}

  ## Callbacks

  @impl true
  def init(phone) do
    state = rehydrate(phone) || fresh_state(phone)
    {:ok, state, @soft_timeout_ms}
  end

  @impl true
  def handle_cast({:message, text, message_id}, state) do
    if message_id && message_id in state.recent_message_ids do
      {:noreply, state, @soft_timeout_ms}
    else
      state = %{
        state
        | last_interaction_at: DateTime.utc_now(),
          recent_message_ids: remember_message_id(state.recent_message_ids, message_id)
      }

      case telegram_link_start(text, state) do
        {:handled, state} ->
          persist(state)
          {:noreply, state, @soft_timeout_ms}

        :not_a_link ->
          case resolve_registered_user(state) do
            {:ok, state} ->
              state = route_message(text, state)
              persist(state)
              {:noreply, state, @soft_timeout_ms}

            :unregistered ->
              {:noreply, state, @soft_timeout_ms}

            :lid_unlinked ->
              state = route_lid_confirmation(text, state)
              persist(state)
              {:noreply, state, @soft_timeout_ms}

            :telegram_unlinked ->
              state = route_telegram_confirmation(text, state)
              persist(state)
              {:noreply, state, @soft_timeout_ms}
          end
      end
    end
  end

  @impl true
  def handle_cast({:daily_quiz, user_id}, state) do
    state = %{state | user_id: user_id, last_interaction_at: DateTime.utc_now()}

    state =
      if state.silenced do
        state
      else
        user = Repo.get!(NursePrep.Accounts.User, user_id)
        dispatch_daily_quiz(state, user)
      end

    persist(state)
    {:noreply, state, @soft_timeout_ms}
  end

  # Only acts if this is still the session's *current* exam — if the
  # student already got the same news via the answer-path check below (or
  # already started a new session), `state.quiz_session_id` has moved on
  # and this cast is a no-op, not a duplicate message.
  @impl true
  def handle_cast({:exam_expired, session_id}, state) do
    state =
      if state.quiz_session_id == session_id do
        expire_and_notify(state, Quizzes.get_session!(session_id))
      else
        state
      end

    persist(state)
    {:noreply, state, @soft_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    persist(state)
    {:noreply, state, :hibernate}
  end

  # Checked *before* `resolve_registered_user/1`-a `/start <token>` deep
  # link (see `Messaging.telegram_deep_link/1`) must be handled the same
  # way no matter whether this chat is already linked to some other
  # account, still unlinked, or mid-quiz on an existing one. Without this,
  # a chat_id that's *already* linked short-circuits straight to
  # `resolve_registered_user`'s `{:ok, state}` clause (the "known
  # identity" fast path), and the token text falls into ordinary quiz
  # command parsing-`{:unrecognized, text}` at best, silently discarded
  # if it happens to be mid-answer. That's exactly what happened the
  # first time this shipped: the same Telegram account already linked to
  # one NursePrep account tried a deep link meant for a second one, and
  # got no feedback at all instead of a clear "already linked elsewhere."
  defp telegram_link_start(text, state) do
    with true <- Messaging.telegram?(state.phone),
         {:ok, token} <- telegram_link_token(text) do
      if Accounts.cold_telegram_login_token?(token) do
        {:handled, start_cold_telegram_login(state, token)}
      else
        {:handled, confirm_telegram_link_start(state, token)}
      end
    else
      _ -> :not_a_link
    end
  end

  # Entry point for the login page's Telegram tab (`Accounts.build_cold_telegram_login_token/0`)-
  # unlike `confirm_telegram_link_start/2`'s token, this one isn't tied to
  # any account yet. Already-linked chat (a returning student logging in on
  # a new device) skips straight to a fresh code; otherwise falls through
  # to the same phone/email prompt as an organic `:telegram_unlinked` chat,
  # just remembering `token` on `state` so `confirm_telegram_link/2` can
  # report back to the browser tab that's waiting on it.
  defp start_cold_telegram_login(state, token) do
    chat_id = Messaging.telegram_chat_id(state.phone)

    case Accounts.get_user_by_telegram_chat_id(chat_id) do
      nil ->
        prompt_telegram_confirmation(%{state | pending_login_token: token})

      user ->
        deliver_cold_login_otp(state, token, user)
    end
  end

  # "stop" is the WhatsApp/SMS-standard opt-out keyword: once sent, the bot
  # goes fully quiet-no replies, no proactive daily quiz drops-until the
  # matching wake keyword comes back, same as texting START to resubscribe
  # after STOP. Silenced state is checked here, ahead of the normal
  # MessageRouter dispatch, so every other command (including a bare "hi" or
  # "help") is a genuine no-op while silenced, not just quiz commands.
  defp route_message(text, %{silenced: true} = state) do
    normalized = text |> String.trim() |> String.downcase()

    if wake_command?(normalized) do
      dispatch(:help, %{state | silenced: false})
    else
      state
    end
  end

  defp route_message(text, state) do
    command = MessageRouter.route(text, state.awaiting)
    dispatch(command, state)
  end

  defp wake_command?(text), do: text in ~w(nurseprep /nurseprep start /start)

  ## Command dispatch

  defp dispatch({:practice, %NursePrep.Questions.Subject{id: subject_id}}, state) do
    start_quiz(state, %{subject_id: subject_id})
  end

  defp dispatch({:practice, nil}, state), do: start_quiz(state, %{})

  defp dispatch({:answer, raw}, %{quiz_session_id: session_id} = state)
       when not is_nil(session_id) do
    session = Quizzes.get_session!(session_id)

    # ExamLive.Show checks this on every "select" before recording an
    # answer; this session never did, so a WhatsApp exam had no real time
    # limit-a student could keep answering (and get credit for it) long
    # after the clock ran out. `exam_over?/1` also catches the case where
    # the cron backstop already expired this session server-side while
    # the student was mid-reply.
    if exam_over?(session) do
      expire_and_notify(state, session)
    else
      label = MessageRouter.answer_to_label(raw)
      current = Enum.at(session.quiz_answers, state.question_index)
      option = Enum.find(current.question.options, &(&1.label == label))

      if option do
        {:ok, _} = Quizzes.answer_question(session, current.question_id, option.id)
        send_feedback_and_advance(state, session, current, option)
      else
        send_text(state.phone, "Please reply with a letter A-D (or 1-4).")
        state
      end
    end
  end

  defp dispatch({:answer, _}, state) do
    send_text(state.phone, "No question is active right now. Text \"practice\" to start one.")
    state
  end

  defp dispatch(:subscribe, state) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)

    case NursePrep.Subscriptions.checkout_url(user) do
      {:ok, url} ->
        send_text(
          state.phone,
          "Upgrade to NursePrep Premium (unlimited practice + mock exams):\n#{url}"
        )

      {:error, _reason} ->
        send_text(
          state.phone,
          "Sorry, payments aren't available right now-please try again shortly."
        )
    end

    state
  end

  defp dispatch(:help, state) do
    send_text(state.phone, help_text())
    state
  end

  defp dispatch(:stats, state) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)
    send_text(state.phone, stats_text(user))
    state
  end

  defp dispatch(:profile, state) do
    send_text(state.phone, profile_text(state.user_id))
    state
  end

  defp dispatch({:leaderboard, scope}, state) do
    board = NursePrep.Analytics.leaderboard(scope)
    send_text(state.phone, leaderboard_text(board, scope, state.user_id))
    state
  end

  defp dispatch(:exam, state) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)

    case NursePrep.Subscriptions.can_start_exam?(user) do
      {:error, :subscription_required} ->
        send_text(
          state.phone,
          "Mock exams are a Premium feature. Reply \"subscribe\" to unlock unlimited practice + timed mock exams."
        )

        state

      :ok ->
        start_exam(state, user)
    end
  end

  defp dispatch(:pause, %{quiz_session_id: nil} = state) do
    send_text(
      state.phone,
      "Nothing to pause right now. Text \"practice\" or \"exam\" to start one."
    )

    state
  end

  defp dispatch(:pause, %{awaiting: nil} = state) do
    send_text(
      state.phone,
      "Already paused on question #{state.question_index + 1}. Text \"resume\" to continue."
    )

    state
  end

  defp dispatch(:pause, state) do
    session = Quizzes.get_session!(state.quiz_session_id)
    total = length(session.quiz_answers)

    timer_note =
      if session.mode == "exam",
        do: " Heads up: the exam clock keeps running while paused.",
        else: ""

    send_text(
      state.phone,
      "⏸️ Paused on question #{state.question_index + 1}/#{total}. Your progress is saved-" <>
        "text \"resume\" to continue, or \"stop\" to end the session for good.#{timer_note}"
    )

    %{state | awaiting: nil}
  end

  defp dispatch(:resume, %{quiz_session_id: nil} = state) do
    send_text(
      state.phone,
      "Nothing paused to resume. Text \"practice\" or \"exam\" to start one."
    )

    state
  end

  defp dispatch(:resume, %{awaiting: :answer} = state) do
    send_text(state.phone, "Already going-nothing paused to resume.")
    state
  end

  defp dispatch(:resume, state) do
    session = Quizzes.get_session!(state.quiz_session_id)

    case session.status do
      "in_progress" ->
        send_question(state.phone, session, state.question_index)
        %{state | awaiting: :answer}

      status ->
        send_text(
          state.phone,
          "That session already ended (#{status})-probably the exam clock running out while " <>
            "paused. Text \"practice\" or \"exam\" to start a new one."
        )

        %{state | quiz_session_id: nil, question_index: 0, awaiting: nil}
    end
  end

  defp dispatch(:stop, %{quiz_session_id: nil} = state) do
    send_text(
      state.phone,
      "🛑 Stopped. I won't send anything else-text \"nurseprep\" or \"start\" whenever you want me back."
    )

    %{state | silenced: true}
  end

  defp dispatch(:stop, state) do
    session = Quizzes.get_session!(state.quiz_session_id)
    answered = state.question_index
    total = length(session.quiz_answers)

    if session.status == "in_progress" do
      {:ok, _} = Quizzes.submit_session(session, "abandoned")
    end

    send_text(
      state.phone,
      "🛑 Session stopped-#{answered}/#{total} answered.\n" <>
        "Review what you answered: #{results_url(session.id)}\n\n" <>
        "I won't send anything else-text \"nurseprep\" or \"start\" whenever you want me back."
    )

    %{state | quiz_session_id: nil, question_index: 0, awaiting: nil, silenced: true}
  end

  defp dispatch(:weak_areas, state) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)

    if NursePrep.Subscriptions.active?(user) do
      {:ok, _job} =
        NursePrep.AiTutor.Workers.TutorWorker.enqueue_weak_areas(
          state.user_id,
          state.phone
        )
    else
      send_tutor_paywall_text(state.phone)
    end

    state
  end

  # The AI tutor only ever replies when explicitly asked via "ask <question>"
  # -never as a silent fallback for anything unrecognized. It used to catch
  # every unmatched message (on the theory that free text was probably a
  # real nursing question), but that meant a stray word like "quiz" got
  # forwarded straight to Grok, whose open-ended answer could itself read
  # like several bundled quiz questions-confusing, costly, and not what
  # was typed for.
  defp dispatch({:ask, question}, state) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)

    if NursePrep.Subscriptions.active?(user) do
      {:ok, _job} =
        NursePrep.AiTutor.Workers.TutorWorker.enqueue(state.user_id, state.phone, question)
    else
      send_tutor_paywall_text(state.phone)
    end

    state
  end

  # No quiz in progress and not a recognized command: nudge toward "help"
  # or the explicit "ask" command rather than guessing what was meant.
  defp dispatch({:unrecognized, _text}, %{quiz_session_id: nil} = state) do
    send_text(
      state.phone,
      "I didn't catch that. Text \"practice\" to start a quiz, \"ask <your question>\" for the AI tutor, or \"help\" to see everything I can do."
    )

    state
  end

  # Mid-quiz, unrecognized text is far more likely a fumbled answer than a
  # new question-a gentle reminder is more helpful (and cheaper) than a
  # Grok round-trip.
  defp dispatch({:unrecognized, _text}, state) do
    send_text(
      state.phone,
      "Please reply with A, B, C, or D to answer the current question-or text \"practice\" to start over."
    )

    state
  end

  defp send_tutor_paywall_text(phone) do
    send_text(
      phone,
      "The AI tutor is a Premium feature. Reply \"subscribe\" to unlock unlimited practice + timed mock exams + the AI tutor."
    )
  end

  ## Quiz flow

  defp start_quiz(state, filters) do
    user = Repo.get!(NursePrep.Accounts.User, state.user_id)

    case NursePrep.Subscriptions.can_start_practice?(user) do
      {:error, :daily_limit_reached} ->
        limit = NursePrep.Subscriptions.free_daily_practice_limit()

        send_text(
          state.phone,
          "You've hit today's free limit (#{limit} questions). Reply \"subscribe\" to go unlimited."
        )

        state

      :ok ->
        do_start_quiz(state, user, filters)
    end
  end

  defp start_exam(state, user) do
    case Quizzes.start_exam_session(user, channel: quiz_channel(state.phone)) do
      {:ok, %{quiz_answers: []}} ->
        send_text(state.phone, "No published questions available for a mock exam right now.")
        state

      {:ok, session} ->
        minutes = div(session.time_limit_seconds, 60)

        send_text(
          state.phone,
          "🕐 Starting your #{session.question_count}-question mock exam (#{minutes} min, NMCN format). Reply A-D for each question."
        )

        send_question(state.phone, session, 0)
        %{state | quiz_session_id: session.id, question_index: 0, awaiting: :answer}
    end
  end

  defp dispatch_daily_quiz(state, user) do
    case Quizzes.start_practice_session(user, %{},
           question_count: 1,
           channel: quiz_channel(state.phone)
         ) do
      {:ok, %{quiz_answers: []}} ->
        state

      {:ok, session} ->
        send_text(state.phone, "🔔 Here's your daily practice question:")
        send_question(state.phone, session, 0)
        %{state | quiz_session_id: session.id, question_index: 0, awaiting: :answer}
    end
  end

  defp do_start_quiz(state, user, filters) do
    case Quizzes.start_practice_session(user, filters, channel: quiz_channel(state.phone)) do
      {:ok, %{quiz_answers: []}} ->
        send_text(
          state.phone,
          "No published questions for that subject yet. Try another one, or just text \"practice\"."
        )

        state

      {:ok, session} ->
        send_question(state.phone, session, 0)
        %{state | quiz_session_id: session.id, question_index: 0, awaiting: :answer}
    end
  end

  # Practice: full feedback, right away-verdict, the correct option's
  # actual text (not just its letter, which meant scrolling back up to see
  # what it even said), and a teaching explanation. Exam: NMCN's real exam
  # never reveals correctness mid-exam, and neither did the web app's
  # ExamLive-this used to give it away immediately regardless of mode,
  # which made a "mock exam" indistinguishable from practice and worthless
  # as an exam-readiness signal.
  defp send_feedback_and_advance(state, session, current, selected_option) do
    next_index = state.question_index + 1
    has_next = next_index < length(session.quiz_answers)

    case session.mode do
      "exam" -> advance_exam(state, session, next_index, has_next)
      _ -> advance_practice(state, session, current, selected_option, next_index, has_next)
    end
  end

  defp advance_practice(state, session, current, selected_option, next_index, has_next) do
    correct_option = Enum.find(current.question.options, & &1.is_correct)

    verdict =
      if selected_option.is_correct do
        "✅ *Correct!*"
      else
        "❌ Not quite. The correct answer is *#{correct_option.label}. #{correct_option.body}*."
      end

    explanation_line =
      case current.question.explanation do
        %{body: body} -> "\n\n💡 #{body}"
        nil -> ""
      end

    send_text(state.phone, verdict <> explanation_line)
    advance_or_finish(state, session, next_index, has_next)
  end

  defp advance_exam(state, session, next_index, has_next) do
    if has_next do
      send_text(state.phone, "✓ Answer recorded.")
      send_question(state.phone, Quizzes.get_session!(session.id), next_index)
      %{state | question_index: next_index}
    else
      finish_session(state, session)
    end
  end

  defp advance_or_finish(state, session, next_index, has_next) do
    if has_next do
      send_question(state.phone, Quizzes.get_session!(session.id), next_index)
      %{state | question_index: next_index}
    else
      finish_session(state, session)
    end
  end

  defp finish_session(state, session) do
    {:ok, submitted} = Quizzes.submit_session(session)

    send_text(
      state.phone,
      "Session complete! Score: #{submitted.score}/#{submitted.question_count}.\n" <>
        "Review your answers: #{results_url(submitted.id)}\n\n#{next_round_prompt(submitted.mode)}"
    )

    %{state | quiz_session_id: nil, question_index: 0, awaiting: nil}
  end

  # Already terminal for any reason (the cron beat us to it, or otherwise)
  # counts as "over" even before checking the clock.
  defp exam_over?(%{status: status}) when status != "in_progress", do: true

  defp exam_over?(%{mode: "exam", expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) == :gt

  defp exam_over?(_session), do: false

  # Shared by both the point a student answers past the deadline (the
  # dispatch({:answer, ...}) clause above) and the cron backstop's
  # proactive push (handle_cast({:exam_expired, ...})) — same message,
  # same state reset, one place to keep them in sync.
  defp expire_and_notify(state, session) do
    {:ok, submitted} =
      if session.status == "in_progress",
        do: Quizzes.submit_session(session, "expired"),
        else: {:ok, session}

    send_text(
      state.phone,
      "⏰ Time's up! Your exam was submitted automatically-Score: #{submitted.score}/#{submitted.question_count}.\n" <>
        "Review your answers: #{results_url(submitted.id)}\n\n#{next_round_prompt(submitted.mode)}"
    )

    %{state | quiz_session_id: nil, question_index: 0, awaiting: nil}
  end

  defp results_url(session_id),
    do: NursePrepWeb.Endpoint.url() <> "/sessions/#{session_id}/results"

  defp next_round_prompt("exam"),
    do: "Text \"exam\" for another mock exam, or \"practice\" to drill untimed."

  defp next_round_prompt(_), do: "Text \"practice\" for another round."

  defp send_question(phone, session, index), do: send_text(phone, question_text(session, index))

  defp question_text(session, index) do
    answer = Enum.at(session.quiz_answers, index)
    question = answer.question

    options_text =
      question.options
      |> Enum.map(&"#{&1.label}. #{&1.body}")
      |> Enum.join("\n")

    header =
      case question.subject do
        %{name: name} -> "*Question #{index + 1}/#{length(session.quiz_answers)}-#{name}*"
        _ -> "*Question #{index + 1}/#{length(session.quiz_answers)}*"
      end

    "#{header}\n\n#{question.stem}\n\n#{options_text}\n\n_Reply with A, B, C, or D._"
  end

  # The WhatsApp equivalent of the web app's nav bar-every section there
  # (Dashboard, Practice, Mock exam, Tutor, Analytics, Leaderboard,
  # Subscription, Profile) has a command here, grouped the same way.
  defp help_text do
    """
    Here's everything I can do:

    📝 *Practice & exams*
    • "practice" (or "quiz")-mixed practice round, untimed
    • "practice <subject>"-e.g. "practice pharmacology"
    • "exam"-timed NMCN-format mock exam (Premium)
    • Reply A-D to answer whichever question is active
    • "pause"-pause your current session, "resume" to pick back up
    • "stop"-end your session and go quiet; text "nurseprep" or "start" to hear from me again

    📊 *Your progress*
    • "stats"-readiness score, streak, accuracy, weak areas
    • "leaderboard"-this week's ranks ("leaderboard all time" for all-time)

    🎓 *AI Tutor* (Premium)
    • "ask <question>"-any nursing/midwifery question, any time
    • "weak areas"-an explanation of your weakest topics

    👤 *Account*
    • "profile"-your saved details
    • "subscribe"-upgrade to Premium

    Text "menu" any time to see this again.
    """
  end

  defp stats_text(user) do
    stats = Quizzes.student_stats(user)
    streak = NursePrep.Analytics.streak(user)
    readiness = NursePrep.Analytics.readiness_score(user)
    weak_areas = NursePrep.Analytics.weak_areas(user)

    weak_areas_text =
      case weak_areas do
        [] ->
          nil

        areas ->
          "Weak areas:\n" <>
            Enum.map_join(areas, "\n", &"• #{&1.topic_name} (#{Formatting.percent(&1.accuracy)})")
      end

    [
      "📊 Your stats",
      "Readiness: #{if readiness, do: Formatting.percent(readiness), else: "not enough data yet"}",
      "Streak: #{streak} day#{if streak == 1, do: "", else: "s"}",
      "Accuracy: #{Formatting.percent(stats.accuracy)}",
      "Questions answered: #{stats.total_answered}",
      weak_areas_text
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp profile_text(user_id) do
    case Accounts.get_profile(user_id) do
      nil ->
        "You haven't set up your profile yet.\nDo that at #{settings_url()}-it's what powers your readiness score."

      profile ->
        [
          "👤 Your profile",
          "Name: #{profile.full_name}",
          "School: #{profile.school || "not set"}",
          "Target NMCN exam date: #{profile.target_exam_date || "not set"}",
          "On the leaderboard: #{yes_no(profile.leaderboard_opt_in)}",
          "Daily WhatsApp quiz: #{yes_no(profile.whatsapp_opt_in)}",
          "",
          "Update any of this at #{settings_url()}"
        ]
        |> Enum.join("\n")
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"

  defp settings_url, do: NursePrepWeb.Endpoint.url() <> "/users/settings"

  defp leaderboard_text(board, scope, user_id) do
    scope_label = if scope == :all_time, do: "All-time", else: "This week's"

    case board do
      [] ->
        "#{scope_label} leaderboard: no ranked activity yet."

      rows ->
        lines =
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {row, i} ->
            marker = if row.user_id == user_id, do: " (you)", else: ""
            "#{medal(i)} #{row.name || "Student"}#{marker}-#{row.correct}/#{row.answered}"
          end)

        "#{scope_label} leaderboard:\n" <> Enum.join(lines, "\n")
    end
  end

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(n), do: "#{n}."

  # Resolves the user for an inbound message *only* if the sender already
  # has a NursePrep account-signing up happens on the web (which sends a
  # real OTP to verify the number), never just by texting the bot. A
  # number's owner receiving a WhatsApp message from this account isn't
  # proof they're a NursePrep user; the account this bot runs on is a real,
  # already-used personal/business number with its own contacts and group
  # chats, and none of that traffic should get auto-enrolled or a reply.
  #
  # `state.phone` is sometimes not a phone number at all — see the `@lid`
  # comment on `WhatsappWebhookController.extract_message/1`, and the
  # tagged-identity comment in this module's moduledoc for Telegram — in
  # which case it's looked up against `whatsapp_lid`/`telegram_chat_id`
  # instead, and `:lid_unlinked`/`:telegram_unlinked` (rather than
  # `:unregistered`) route to a confirmation flow instead of staying
  # silent, since we can't yet tell whether this really is an existing
  # student until they confirm their phone number (or, for Telegram,
  # email) once.
  defp resolve_registered_user(%{user_id: nil, phone: identifier} = state) do
    cond do
      Messaging.telegram?(identifier) ->
        case Accounts.get_user_by_telegram_chat_id(Messaging.telegram_chat_id(identifier)) do
          nil -> :telegram_unlinked
          user -> {:ok, %{state | user_id: user.id}}
        end

      Messaging.whatsapp_lid?(identifier) ->
        case Accounts.get_user_by_whatsapp_lid(identifier) do
          nil -> :lid_unlinked
          user -> {:ok, %{state | user_id: user.id}}
        end

      true ->
        case Accounts.get_user_by_phone(identifier) do
          nil -> :unregistered
          user -> {:ok, %{state | user_id: user.id}}
        end
    end
  end

  defp resolve_registered_user(state), do: {:ok, state}

  # A `@lid` contact we haven't linked to an account yet. Stays in this
  # state indefinitely (same pattern as an outstanding quiz question
  # awaiting A-D) until either a matching phone number is confirmed or the
  # student says "stop" — reusing `MessageRouter`'s own stop-word
  # recognition rather than a second copy of that keyword list.
  defp route_lid_confirmation(text, state) do
    if MessageRouter.route(text, nil) == :stop do
      send_text(state.phone, "🛑 Okay, I won't message you again.")
      %{state | silenced: true, awaiting: nil}
    else
      case PhoneNumber.normalize(text) do
        {:ok, normalized} -> confirm_lid_phone(state, normalized)
        {:error, _reason} -> prompt_lid_confirmation(state)
      end
    end
  end

  defp confirm_lid_phone(state, normalized_phone) do
    case Accounts.get_user_by_phone(normalized_phone) do
      nil ->
        send_text(
          state.phone,
          "I couldn't find a NursePrep account for #{normalized_phone}. Sign up at " <>
            "#{NursePrepWeb.Endpoint.url()}, then message your phone number again-or text " <>
            "\"stop\" to not hear from me."
        )

        %{state | awaiting: :phone_confirmation}

      user ->
        case Accounts.link_whatsapp_lid(user, state.phone) do
          {:ok, _user} ->
            dispatch(:help, %{state | user_id: user.id, awaiting: nil})

          {:error, _changeset} ->
            send_text(
              state.phone,
              "Something went wrong linking that number-please try again in a moment."
            )

            %{state | awaiting: :phone_confirmation}
        end
    end
  end

  defp prompt_lid_confirmation(%{awaiting: :phone_confirmation} = state) do
    send_text(
      state.phone,
      "Please reply with just your phone number (e.g. +2348012345678), or text \"stop\"."
    )

    state
  end

  defp prompt_lid_confirmation(state) do
    send_text(
      state.phone,
      "👋 Hi! WhatsApp shared a private ID instead of your number, so I need to confirm it's " <>
        "really you. What's the phone number on your NursePrep account? (or text \"stop\" to " <>
        "not hear from me)"
    )

    %{state | awaiting: :phone_confirmation}
  end

  # A Telegram chat id we haven't linked to an account yet. Same shape as
  # `route_lid_confirmation/2`, widened to accept phone *or* email-unlike
  # WhatsApp users (inherently phone-based), a Telegram-linkable student
  # may have signed up with email only. A `/start <token>` deep link is
  # already handled upstream in `telegram_link_start/2` before this is
  # ever reached (a *linked* chat needs that same interception, so it
  # can't live only here)-a bare `/start` with no payload just falls
  # through to `identify_by_phone_or_email/1` below like any other
  # unrecognized text.
  defp route_telegram_confirmation(text, state) do
    if MessageRouter.route(text, nil) == :stop do
      send_text(state.phone, "🛑 Okay, I won't message you again.")
      %{state | silenced: true, awaiting: nil, pending_login_token: nil}
    else
      # A cold login (`state.pending_login_token` set, see
      # `start_cold_telegram_login/2`) is allowed to create a brand new
      # account for a phone/email nobody's typed before-that's the whole
      # point of the login page's Telegram tab. An organic, token-less
      # `:telegram_unlinked` chat (someone found the bot on their own, or a
      # student linking a *second* Telegram to an *existing* NursePrep
      # account) stays lookup-only, same as before: texting the bot has
      # never been how an account gets created outside of this cold-login
      # path, and it shouldn't quietly start doing so here either.
      result =
        if state.pending_login_token do
          identify_or_create_by_phone_or_email(text)
        else
          identify_by_phone_or_email(text)
        end

      case result do
        {:ok, user} -> confirm_telegram_link(state, user)
        :error -> prompt_telegram_confirmation(state)
      end
    end
  end

  defp telegram_link_token("/start " <> token) when byte_size(token) > 0, do: {:ok, token}
  defp telegram_link_token(_text), do: :error

  defp identify_by_phone_or_email(text) do
    case PhoneNumber.normalize(text) do
      {:ok, phone} ->
        case Accounts.get_user_by_phone(phone) do
          nil -> :error
          user -> {:ok, user}
        end

      {:error, _reason} ->
        case EmailAddress.normalize(text) do
          {:ok, email} ->
            case Accounts.get_user_by_email(email) do
              nil -> :error
              user -> {:ok, user}
            end

          {:error, _reason} ->
            :error
        end
    end
  end

  defp identify_or_create_by_phone_or_email(text) do
    case PhoneNumber.normalize(text) do
      {:ok, phone} ->
        {:ok, Accounts.get_user_by_phone(phone) || Accounts.insert_user_by_phone!(phone)}

      {:error, _reason} ->
        case EmailAddress.normalize(text) do
          {:ok, email} ->
            {:ok, Accounts.get_user_by_email(email) || Accounts.insert_user_by_email!(email)}

          {:error, _reason} ->
            :error
        end
    end
  end

  defp confirm_telegram_link(state, user) do
    chat_id = Messaging.telegram_chat_id(state.phone)

    case Accounts.link_telegram_chat_id(user, chat_id) do
      {:ok, user} ->
        state = %{state | user_id: user.id, awaiting: nil}

        if state.pending_login_token do
          deliver_cold_login_otp(state, state.pending_login_token, user)
        else
          dispatch(:help, state)
        end

      {:error, _changeset} ->
        send_text(
          state.phone,
          "Something went wrong linking your account-please try again in a moment."
        )

        %{state | awaiting: :telegram_confirmation}
    end
  end

  # Fires the login OTP straight into this chat and reports success back to
  # whichever login-page tab is subscribed on `token`'s topic (see
  # `Accounts.build_cold_telegram_login_token/0`)-the counterpart to
  # `notify_telegram_login_otp_sent/3` for the cold-start path, generalized
  # to an email-identified account since a cold login isn't guaranteed to
  # land on a phone the way the existing WhatsApp-down nudge always did.
  # Also the resend path for a chat that's already linked (a returning
  # student opening the Telegram tab on a new device)-`confirm_telegram_link/2`
  # only calls this after actually linking, but `start_cold_telegram_login/2`
  # calls it directly for an already-linked chat, so this can't assume the
  # link step just happened.
  defp deliver_cold_login_otp(state, token, user) do
    kind = identifier_kind(user)
    sent_to = if kind == :phone, do: user.phone, else: user.email

    send_text(state.phone, "✅ Got it! Sending your NursePrep login code now...")

    otp_result =
      if kind == :phone,
        do: Accounts.send_telegram_login_otp(user),
        else: Accounts.send_telegram_login_email_otp(user)

    case otp_result do
      {:ok, _user} ->
        Phoenix.PubSub.broadcast(
          NursePrep.PubSub,
          Accounts.telegram_link_topic(token),
          {:telegram_cold_login_completed, kind, sent_to}
        )

      {:error, _reason} ->
        send_text(
          state.phone,
          "Something went wrong sending your login code. Please go back to NursePrep and try again."
        )
    end

    %{state | pending_login_token: nil}
  end

  defp identifier_kind(%{phone: phone}) when is_binary(phone), do: :phone
  defp identifier_kind(_user), do: :email

  # For the `:login` purpose (the login page's WhatsApp-down nudge), confirm
  # the link *then* fire the login OTP as an explicit, ordered second
  # send-`Accounts.confirm_telegram_link_token/2` deliberately does neither
  # send itself (see its doc), so this is the one place that decides both
  # that it happens and that it happens in that order, rather than a
  # 6-digit code with no context landing before the student even knows
  # what just happened. `:settings` (a logged-in student linking from
  # Settings, no pending login to unblock) gets the normal
  # `dispatch(:help, ...)` command menu instead, same as
  # `confirm_telegram_link/2`'s phone/email path.
  defp confirm_telegram_link_start(state, token) do
    chat_id = Messaging.telegram_chat_id(state.phone)

    case Accounts.confirm_telegram_link_token(token, chat_id) do
      {:ok, user, :login} ->
        send_text(state.phone, "✅ Telegram linked! Sending your NursePrep login code now...")
        notify_telegram_login_otp_sent(state.phone, token, user)
        %{state | user_id: user.id, awaiting: nil}

      {:ok, user, :settings} ->
        dispatch(:help, %{state | user_id: user.id, awaiting: nil})

      {:error, :chat_already_linked} ->
        send_text(
          state.phone,
          "This Telegram account is already linked to a different NursePrep account, so it " <>
            "can't also link here-one Telegram account can only be linked to one NursePrep " <>
            "account at a time. To free it up, log into that other account on the web, open " <>
            "Settings, and unlink Telegram there, then try this link again."
        )

        state

      {:error, _reason} ->
        send_text(
          state.phone,
          "That link has expired or was already used. Please request a fresh one from " <>
            "NursePrep, or reply here with your phone number or email to link manually."
        )

        prompt_telegram_confirmation(state)
    end
  end

  # Tapping Start happens inside the Telegram app-a different process
  # entirely from the browser tab that's sitting on the login page's
  # "link Telegram" nudge, so nothing short of an explicit push tells that
  # tab a code is now waiting. Broadcasts on `Accounts.telegram_link_topic/1`
  # (the login LiveView subscribes to it the moment it shows the nudge) so
  # that tab can jump straight to the code-entry step with no reload and no
  # resubmitting the form-previously the only way forward from there was
  # to refresh (losing the in-progress `:code` step state) and retype the
  # phone number, burning a second otp_request rate-limit slot for a code
  # that had already gone out. Only fires when the send actually succeeded;
  # a delivery failure here gets its own message instead, so the browser
  # tab never jumps to a code-entry screen for a code that was never sent.
  defp notify_telegram_login_otp_sent(telegram_identity, token, user) do
    case Accounts.send_telegram_login_otp(user) do
      {:ok, _user} ->
        Phoenix.PubSub.broadcast(
          NursePrep.PubSub,
          Accounts.telegram_link_topic(token),
          {:telegram_link_completed, user.phone}
        )

      {:error, _reason} ->
        send_text(
          telegram_identity,
          "Something went wrong sending your login code. Please go back to NursePrep and try again."
        )
    end
  end

  defp prompt_telegram_confirmation(%{awaiting: :telegram_confirmation} = state) do
    send_text(
      state.phone,
      "Please reply with just your phone number or the email on your NursePrep account, or text \"stop\"."
    )

    state
  end

  defp prompt_telegram_confirmation(state) do
    send_text(
      state.phone,
      "👋 Hi! To link this Telegram account, what's the phone number or email on your " <>
        "NursePrep account? (or text \"stop\" to not hear from me)"
    )

    %{state | awaiting: :telegram_confirmation}
  end

  defp remember_message_id(recent_ids, nil), do: recent_ids

  defp remember_message_id(recent_ids, message_id),
    do: Enum.take([message_id | recent_ids], @max_recent_message_ids)

  defp send_text(identity, text) do
    case Messaging.send_text(identity, text) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("send_text failed for #{identity}: #{inspect(reason)}")
    end
  end

  # Whichever channel actually delivered this message-`QuizSession`/
  # `Conversation` both persist it, so analytics and the admin dashboard
  # can tell a Telegram exam from a WhatsApp one.
  defp quiz_channel(identity) do
    if Messaging.telegram?(identity), do: "telegram", else: "whatsapp"
  end

  ## Persistence (crash recovery)

  defp fresh_state(phone) do
    %{
      phone: phone,
      user_id: nil,
      quiz_session_id: nil,
      question_index: 0,
      awaiting: nil,
      silenced: false,
      last_interaction_at: DateTime.utc_now(),
      recent_message_ids: [],
      pending_login_token: nil
    }
  end

  defp rehydrate(phone) do
    case Repo.get_by(WhatsappSession, phone: phone) do
      nil ->
        nil

      %{expires_at: expires_at, state: state} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          Repo.delete_all(from_phone_query(phone))
          nil
        else
          %{
            phone: phone,
            user_id: state["user_id"],
            quiz_session_id: state["quiz_session_id"],
            question_index: state["question_index"] || 0,
            awaiting: state["awaiting"] && String.to_existing_atom(state["awaiting"]),
            silenced: state["silenced"] || false,
            last_interaction_at: DateTime.utc_now(),
            recent_message_ids: [],
            pending_login_token: state["pending_login_token"]
          }
        end
    end
  end

  defp persist(state) do
    attrs = %{
      "phone" => state.phone,
      "state" => %{
        "user_id" => state.user_id,
        "quiz_session_id" => state.quiz_session_id,
        "question_index" => state.question_index,
        "awaiting" => state.awaiting && to_string(state.awaiting),
        "silenced" => state.silenced,
        "pending_login_token" => state.pending_login_token
      },
      "expires_at" =>
        DateTime.add(DateTime.utc_now(), @hard_expiry_seconds, :second)
        |> DateTime.truncate(:second)
    }

    case Repo.get_by(WhatsappSession, phone: state.phone) do
      nil -> %WhatsappSession{} |> WhatsappSession.changeset(attrs) |> Repo.insert()
      existing -> existing |> WhatsappSession.changeset(attrs) |> Repo.update()
    end
  end

  defp from_phone_query(phone) do
    import Ecto.Query
    from(s in WhatsappSession, where: s.phone == ^phone)
  end
end
