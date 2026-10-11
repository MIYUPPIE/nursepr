defmodule NursePrepWeb.UserLive.Settings do
  use NursePrepWeb, :live_view

  on_mount {NursePrepWeb.UserAuth, :require_authenticated}

  alias NursePrep.{Accounts, Messaging}
  alias NursePrep.Accounts.Profile

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student flash={@flash} current_scope={@current_scope} active={:settings}>
      <div class="mx-auto max-w-lg">
        <.header icon="hero-user-circle">
          Your profile
          <:subtitle>
            This is what powers your readiness score.
          </:subtitle>
        </.header>

        <div class="card bg-base-100 border border-base-300 mt-4">
          <div class="card-body">
            <.form for={@form} id="profile_form" phx-submit="save" phx-change="validate">
              <.input field={@form[:full_name]} type="text" label="Full name" required />
              <.input field={@form[:school]} type="text" label="School of Nursing" />
              <.input field={@form[:target_exam_date]} type="date" label="Target NMCN exam date" />
              <.input
                field={@form[:leaderboard_opt_in]}
                type="checkbox"
                label="Show me on the leaderboard"
              />
              <.input
                :if={@current_scope.user.phone}
                field={@form[:whatsapp_opt_in]}
                type="checkbox"
                label="Send me the daily WhatsApp quiz"
              />
              <.button variant="primary" phx-disable-with="Saving..." class="w-full mt-2">
                Save profile
              </.button>
            </.form>
          </div>
        </div>

        <div id="whatsapp-card" class="card bg-base-100 border border-base-300 mt-4">
          <div class="card-body">
            <h2 class="card-title text-base">WhatsApp</h2>

            <div :if={@current_scope.user.phone}>
              <p class="text-sm">
                ✅ Linked to <span class="font-semibold">{@current_scope.user.phone}</span>.
              </p>
            </div>

            <div :if={is_nil(@current_scope.user.phone) and @phone_link_step == :idle}>
              <p class="text-sm text-base-content/70 mb-2">
                Add your WhatsApp number to also get quizzes and reminders there.
              </p>
              <.form for={@phone_link_form} id="phone_link_form" phx-submit="request_phone_link">
                <.input field={@phone_link_form[:phone]} type="text" label="WhatsApp number" required />
                <.button variant="primary" phx-disable-with="Sending..." class="w-full mt-2">
                  Send code
                </.button>
              </.form>
            </div>

            <div :if={@phone_link_step == :code_sent}>
              <p class="text-sm text-base-content/70 mb-2">
                Enter the code sent to <span class="font-semibold">{@pending_phone}</span>
                on WhatsApp.
              </p>
              <.form
                for={@phone_link_code_form}
                id="phone_link_code_form"
                phx-submit="confirm_phone_link"
              >
                <.input field={@phone_link_code_form[:code]} type="text" label="Code" required />
                <.button variant="primary" phx-disable-with="Verifying..." class="w-full mt-2">
                  Confirm
                </.button>
              </.form>
              <button type="button" class="link text-sm mt-2" phx-click="cancel_phone_link">
                Use a different number
              </button>
            </div>
          </div>
        </div>

        <div id="email-card" class="card bg-base-100 border border-base-300 mt-4">
          <div class="card-body">
            <h2 class="card-title text-base">Email</h2>

            <div :if={@current_scope.user.email}>
              <p class="text-sm">
                ✅ Linked to <span class="font-semibold">{@current_scope.user.email}</span>.
              </p>
            </div>

            <div :if={is_nil(@current_scope.user.email) and @email_link_step == :idle}>
              <p class="text-sm text-base-content/70 mb-2">
                Add an email so you can also log in without WhatsApp, and so we can reach you if
                it's ever unavailable.
              </p>
              <.form for={@email_link_form} id="email_link_form" phx-submit="request_email_link">
                <.input field={@email_link_form[:email]} type="email" label="Email address" required />
                <.button variant="primary" phx-disable-with="Sending..." class="w-full mt-2">
                  Send code
                </.button>
              </.form>
            </div>

            <div :if={@email_link_step == :code_sent}>
              <p class="text-sm text-base-content/70 mb-2">
                Enter the code sent to <span class="font-semibold">{@pending_email}</span>.
              </p>
              <.form
                for={@email_link_code_form}
                id="email_link_code_form"
                phx-submit="confirm_email_link"
              >
                <.input field={@email_link_code_form[:code]} type="text" label="Code" required />
                <.button variant="primary" phx-disable-with="Verifying..." class="w-full mt-2">
                  Confirm
                </.button>
              </.form>
              <button type="button" class="link text-sm mt-2" phx-click="cancel_email_link">
                Use a different email
              </button>
            </div>
          </div>
        </div>

        <div id="telegram-card" class="card bg-base-100 border border-base-300 mt-4">
          <div class="card-body">
            <h2 class="card-title text-base">Telegram</h2>

            <div :if={@current_scope.user.telegram_chat_id}>
              <p class="text-sm">
                ✅ Linked. You'll get quizzes and reminders there too-and it's the automatic
                backup if WhatsApp is ever unavailable.
              </p>
              <button
                type="button"
                class="btn btn-ghost btn-sm mt-2"
                phx-click="unlink_telegram"
                data-confirm="Unlink Telegram from this account? You can link it again any time-including to a different NursePrep account, if that's what you're trying to do."
              >
                Unlink
              </button>
            </div>

            <div :if={is_nil(@current_scope.user.telegram_chat_id) and @telegram_bot_url}>
              <p class="text-sm text-base-content/70 mb-2">
                Telegram also works as a backup channel if WhatsApp is ever down. Tap below, then
                tap Start-your account links automatically, no typing required.
              </p>
              <a
                href={@telegram_deep_link || @telegram_bot_url}
                target="_blank"
                class="btn btn-primary w-full"
              >
                Open the NursePrep Telegram bot
              </a>
            </div>
          </div>
        </div>
      </div>
    </Layouts.student>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    profile = Accounts.get_profile(user.id) || %Profile{user_id: user.id}
    changeset = Accounts.change_profile(profile)

    {:ok,
     socket
     |> assign(profile: profile, form: to_form(changeset))
     |> assign(phone_link_step: :idle, pending_phone: nil)
     |> assign(phone_link_form: to_form(%{"phone" => ""}, as: "phone_link"))
     |> assign(phone_link_code_form: to_form(%{"code" => ""}, as: "phone_link_code"))
     |> assign(email_link_step: :idle, pending_email: nil)
     |> assign(email_link_form: to_form(%{"email" => ""}, as: "email_link"))
     |> assign(email_link_code_form: to_form(%{"code" => ""}, as: "email_link_code"))
     |> assign(telegram_bot_url: Messaging.telegram_bot_url())
     |> assign(telegram_deep_link: maybe_telegram_deep_link(user))}
  end

  # Only worth a token (and a DB row) when there's actually an unlinked
  # Telegram card to show it on-skips the write entirely for a student
  # who's already linked, or when TELEGRAM_BOT_USERNAME isn't configured
  # and the card renders no button at all.
  defp maybe_telegram_deep_link(%{telegram_chat_id: nil} = user) do
    case Messaging.telegram_bot_url() do
      nil -> nil
      _url -> user |> Accounts.request_telegram_link_token() |> Messaging.telegram_deep_link()
    end
  end

  defp maybe_telegram_deep_link(_user), do: nil

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    changeset =
      socket.assigns.profile
      |> Accounts.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"profile" => params}, socket) do
    user = socket.assigns.current_scope.user

    result =
      case socket.assigns.profile do
        %Profile{id: nil} -> Accounts.create_profile(user.id, params)
        profile -> Accounts.update_profile(profile, params)
      end

    case result do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(profile: profile, form: to_form(Accounts.change_profile(profile)))
         |> put_flash(:info, "Profile saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("request_phone_link", %{"phone_link" => %{"phone" => phone}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.request_phone_link(user, phone) do
      {:ok, normalized} ->
        {:noreply,
         socket
         |> assign(phone_link_step: :code_sent, pending_phone: normalized)
         |> put_flash(:info, "Code sent! Check WhatsApp.")}

      {:error, :phone_taken} ->
        {:noreply,
         put_flash(socket, :error, "That number is already linked to a different account.")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many requests. Please wait a few minutes.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a valid WhatsApp number.")}
    end
  end

  def handle_event(
        "confirm_phone_link",
        %{"phone_link_code" => %{"code" => code}},
        socket
      ) do
    user = socket.assigns.current_scope.user
    phone = socket.assigns.pending_phone

    case Accounts.confirm_phone_link(user, phone, code) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> assign(phone_link_step: :idle, pending_phone: nil)
         |> put_flash(:info, "WhatsApp number linked!")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many attempts. Please wait a few minutes.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That code is invalid or expired.")}
    end
  end

  def handle_event("cancel_phone_link", _params, socket) do
    {:noreply, assign(socket, phone_link_step: :idle, pending_phone: nil)}
  end

  def handle_event("request_email_link", %{"email_link" => %{"email" => email}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.request_email_link(user, email) do
      {:ok, normalized} ->
        {:noreply,
         socket
         |> assign(email_link_step: :code_sent, pending_email: normalized)
         |> put_flash(:info, "Code sent! Check your inbox.")}

      {:error, :email_taken} ->
        {:noreply,
         put_flash(socket, :error, "That email is already linked to a different account.")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many requests. Please wait a few minutes.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a valid email address.")}
    end
  end

  def handle_event(
        "confirm_email_link",
        %{"email_link_code" => %{"code" => code}},
        socket
      ) do
    user = socket.assigns.current_scope.user
    email = socket.assigns.pending_email

    case Accounts.confirm_email_link(user, email, code) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> assign(email_link_step: :idle, pending_email: nil)
         |> put_flash(:info, "Email linked!")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many attempts. Please wait a few minutes.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That code is invalid or expired.")}
    end
  end

  def handle_event("cancel_email_link", _params, socket) do
    {:noreply, assign(socket, email_link_step: :idle, pending_email: nil)}
  end

  def handle_event("unlink_telegram", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.unlink_telegram_chat_id(user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_scope: %{socket.assigns.current_scope | user: updated_user})
         |> assign(telegram_deep_link: maybe_telegram_deep_link(updated_user))
         |> put_flash(:info, "Telegram unlinked.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Something went wrong unlinking Telegram-please try again.")}
    end
  end
end
