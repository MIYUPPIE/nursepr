defmodule NursePrepWeb.UserLive.Login do
  use NursePrepWeb, :live_view

  alias NursePrep.Accounts
  alias NursePrep.Messaging

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_w="max-w-4xl">
      <div class="flex items-center justify-center min-h-[calc(100vh-10rem)] py-6">
        <div class="w-full rounded-3xl overflow-hidden border border-base-300 bg-base-100 shadow-2xl shadow-base-300/50 lg:flex">
          <div class="hidden lg:flex lg:w-[42%] relative flex-col justify-between p-10 bg-gradient-to-br from-primary to-primary/80 text-primary-content overflow-hidden">
            <div
              class="absolute -right-16 -top-16 size-72 rounded-full bg-white/10 blur-3xl"
              aria-hidden="true"
            >
            </div>
            <div
              class="absolute -left-10 bottom-24 size-56 rounded-full bg-accent/30 blur-3xl"
              aria-hidden="true"
            >
            </div>

            <div class="relative flex items-center gap-2.5">
              <div class="size-9 rounded-lg bg-white/15 flex items-center justify-center shrink-0">
                <img src={~p"/images/logo.svg"} width="20" height="20" />
              </div>
              <span class="font-bold text-lg">NursePrep</span>
            </div>

            <div class="relative">
              <p class="text-2xl font-extrabold tracking-tight text-balance leading-snug">
                Walk into your exam already knowing <span class="italic">you'll pass</span>.
              </p>
              <ul class="mt-6 space-y-3 text-sm text-primary-content/90">
                <li class="flex items-center gap-2.5">
                  <.icon name="hero-check-circle" class="size-4 shrink-0" />
                  Untimed practice with instant feedback
                </li>
                <li class="flex items-center gap-2.5">
                  <.icon name="hero-check-circle" class="size-4 shrink-0" />
                  Timed mock exams, real NMCN format
                </li>
                <li class="flex items-center gap-2.5">
                  <.icon name="hero-check-circle" class="size-4 shrink-0" />
                  Daily quiz drop on WhatsApp or Telegram
                </li>
              </ul>
            </div>
          </div>

          <div class="flex-1 p-6 sm:p-10 lg:p-12 flex flex-col justify-center">
            <div class="mx-auto w-full max-w-sm">
              <div class="mb-6">
                <img
                  src={~p"/images/logo.svg"}
                  width="36"
                  height="36"
                  class="mb-4 lg:hidden"
                />
                <h1 class="text-2xl font-extrabold tracking-tight">
                  {if @step == :code, do: "Enter your code", else: "Welcome to NursePrep"}
                </h1>
                <p class="mt-1.5 text-sm text-base-content/60 text-balance">
                  <%= cond do %>
                    <% @step == :code -> %>
                      We sent a 6-digit code to <span class="font-medium text-base-content">{@channel == :phone && @phone || @email}</span>.
                    <% true -> %>
                      One step logs you in, or creates your account if you're new.
                  <% end %>
                </p>
              </div>

              <div
                :if={@step == :identifier and length(@visible_channels) > 1}
                class={["tabs tabs-box w-full grid mb-6", tabs_grid_class(length(@visible_channels))]}
              >
                <button
                  :for={ch <- @visible_channels}
                  type="button"
                  class={["tab gap-1.5", @channel == ch && "tab-active"]}
                  phx-click="switch_channel"
                  phx-value-channel={ch}
                >
                  <.icon name={channel_icon(ch)} class="size-4" />
                  {channel_label(ch)}
                </button>
              </div>

              <div :if={@dev_otp} class="alert alert-info mb-5 text-sm items-start">
                <.icon name="hero-information-circle" class="size-5 shrink-0 mt-0.5" />
                <div>
                  <p class="font-semibold">Dev mode</p>
                  <p class="text-base-content/70">{@dev_otp}</p>
                </div>
              </div>

              <.form
                :if={@step == :identifier and @channel == :phone}
                for={@phone_form}
                id="phone_form"
                phx-submit="request_code"
              >
                <label class="text-sm font-medium mb-1.5 block" for={@phone_form[:phone].id}>
                  WhatsApp number
                </label>
                <label class="input input-lg w-full">
                  <.icon name="hero-device-phone-mobile" class="size-5 opacity-50 shrink-0" />
                  <input
                    type="tel"
                    name={@phone_form[:phone].name}
                    id={@phone_form[:phone].id}
                    value={@phone_form[:phone].value}
                    placeholder="08012345678"
                    autocomplete="tel"
                    required
                    phx-mounted={JS.focus()}
                  />
                </label>
                <p class="mt-2 text-xs text-base-content/50">
                  We'll message you a 6-digit code. No password needed.
                </p>
                <.button class="btn btn-primary btn-lg w-full mt-5" phx-disable-with="Sending...">
                  Send code <span aria-hidden="true">→</span>
                </.button>
              </.form>

              <div :if={@step == :identifier and @channel == :telegram} class="text-center py-1">
                <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-primary/10 text-primary">
                  <.icon name="hero-paper-airplane" class="size-6" />
                </div>
                <p class="mt-4 text-sm text-base-content/70 text-balance">
                  Message the NursePrep bot on Telegram with your phone number or email.
                  We'll link your account (or set one up) and send your login code right there.
                </p>
                <a
                  href={@telegram_deep_link}
                  target="_blank"
                  class="btn btn-primary btn-lg w-full mt-5"
                >
                  <.icon name="hero-paper-airplane" class="size-4" /> Open the NursePrep Telegram bot
                </a>
                <p class="mt-3 text-xs text-base-content/50">
                  This page jumps to the code step automatically once you message the bot.
                </p>
              </div>

              <.form
                :if={@step == :identifier and @channel == :email}
                for={@email_form}
                id="email_form"
                phx-submit="request_code"
              >
                <label class="text-sm font-medium mb-1.5 block" for={@email_form[:email].id}>
                  Email address
                </label>
                <label class="input input-lg w-full">
                  <.icon name="hero-envelope" class="size-5 opacity-50 shrink-0" />
                  <input
                    type="email"
                    name={@email_form[:email].name}
                    id={@email_form[:email].id}
                    value={@email_form[:email].value}
                    placeholder="you@example.com"
                    autocomplete="email"
                    required
                    phx-mounted={JS.focus()}
                  />
                </label>
                <p class="mt-2 text-xs text-base-content/50">
                  We'll email you a 6-digit code. No password needed.
                </p>
                <.button class="btn btn-primary btn-lg w-full mt-5" phx-disable-with="Sending...">
                  Send code <span aria-hidden="true">→</span>
                </.button>
              </.form>

              <.form
                :if={@step == :code}
                for={@code_form}
                id="code_form"
                action={~p"/users/log-in"}
                method="post"
                phx-submit="submit_code"
                phx-trigger-action={@trigger_submit}
              >
                <input
                  :if={@channel == :phone}
                  type="hidden"
                  name={@code_form[:phone].name}
                  value={@phone}
                />
                <input
                  :if={@channel == :email}
                  type="hidden"
                  name={@code_form[:email].name}
                  value={@email}
                />
                <label class="text-sm font-medium mb-1.5 block" for={@code_form[:code].id}>
                  Login code
                </label>
                <input
                  type="text"
                  name={@code_form[:code].name}
                  id={@code_form[:code].id}
                  value={@code_form[:code].value}
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  maxlength="6"
                  required
                  placeholder="––––––"
                  class="input input-lg w-full text-center text-2xl font-mono tracking-[0.5em]"
                  phx-mounted={JS.focus()}
                />
                <.button class="btn btn-primary btn-lg w-full mt-5" phx-disable-with="Verifying...">
                  Log in <span aria-hidden="true">→</span>
                </.button>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm w-full mt-2"
                  phx-click="change_number"
                >
                  <.icon name="hero-arrow-left" class="size-4" />
                  Use a different {if @channel == :phone, do: "number", else: "email"}
                </button>
              </.form>

              <p class="text-center text-xs text-base-content/50 mt-8 lg:hidden">
                NursePrep exam prep for Nigerian nursing licensure candidates.
              </p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    whatsapp_enabled? = whatsapp_enabled?()
    telegram_bot_url = Messaging.telegram_bot_url()
    telegram_available? = not is_nil(telegram_bot_url)

    cold_telegram_token = if telegram_available?, do: Accounts.build_cold_telegram_login_token()

    telegram_deep_link =
      if cold_telegram_token, do: Messaging.telegram_deep_link(cold_telegram_token)

    if connected?(socket) and telegram_available? do
      Phoenix.PubSub.subscribe(
        NursePrep.PubSub,
        Accounts.telegram_link_topic(cold_telegram_token)
      )
    end

    visible_channels =
      [{:phone, whatsapp_enabled?}, {:telegram, telegram_available?}, {:email, true}]
      |> Enum.filter(fn {_channel, available?} -> available? end)
      |> Enum.map(fn {channel, _available?} -> channel end)

    {:ok,
     socket
     |> assign(
       step: :identifier,
       channel: List.first(visible_channels, :email),
       visible_channels: visible_channels,
       phone: nil,
       email: nil,
       dev_otp: nil,
       trigger_submit: false,
       whatsapp_enabled?: whatsapp_enabled?,
       email_enabled?: email_enabled?(),
       telegram_deep_link: telegram_deep_link
     )
     |> assign(phone_form: to_form(%{"phone" => ""}, as: "user"))
     |> assign(email_form: to_form(%{"email" => ""}, as: "user"))
     |> assign(code_form: to_form(%{"code" => ""}, as: "user"))}
  end

  @impl true
  def handle_event("switch_channel", %{"channel" => channel}, socket) do
    channel = String.to_existing_atom(channel)

    if channel in socket.assigns.visible_channels do
      {:noreply, assign(socket, channel: channel)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_code", %{"user" => %{"phone" => phone}}, socket) do
    case Accounts.request_otp(phone) do
      {:ok, user, channel} ->
        flash = request_code_flash(channel)

        {:noreply,
         socket
         |> assign(step: :code, channel: :phone, phone: user.phone, dev_otp: nil)
         |> put_flash(:info, flash)}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many requests. Please wait a few minutes.")}

      {:error, :delivery_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We couldn't send that code right now. Please try again in a moment."
         )}

      {:error, :whatsapp_unavailable} ->
        {:noreply, put_flash(socket, :error, whatsapp_unavailable_flash(socket))}

      {:error, :whatsapp_unavailable_no_fallback, _telegram_token} ->
        {:noreply, put_flash(socket, :error, whatsapp_unavailable_flash(socket))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a valid WhatsApp number.")}
    end
  end

  def handle_event("request_code", %{"user" => %{"email" => email}}, socket) do
    case Accounts.request_email_otp(email) do
      {:ok, user, channel} ->
        flash = request_email_flash(channel, socket.assigns.email_enabled?)

        {:noreply,
         socket
         |> assign(step: :code, channel: :email, email: user.email, dev_otp: dev_otp_hint(:email))
         |> put_flash(:info, flash)}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many requests. Please wait a few minutes.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a valid email address.")}
    end
  end

  def handle_event("submit_code", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("change_number", _params, socket) do
    {:noreply,
     assign(socket,
       step: :identifier,
       phone: nil,
       email: nil,
       dev_otp: nil
     )}
  end

  # Fired by `Whatsapp.Session.deliver_cold_login_otp/3` the instant the
  # student finishes the Telegram tab's link-or-create exchange (typing
  # their phone or email into the bot after tapping "Open the NursePrep
  # Telegram bot")-see `Accounts.build_cold_telegram_login_token/0`. Jumps
  # straight to the code-entry step with no reload, same shape as a normal
  # successful `request_code` for whichever identifier the student typed.
  @impl true
  def handle_info({:telegram_cold_login_completed, :phone, phone}, socket) do
    {:noreply,
     socket
     |> assign(step: :code, channel: :phone, phone: phone, dev_otp: nil)
     |> put_flash(:info, "Telegram linked! Check Telegram for your code.")}
  end

  def handle_info({:telegram_cold_login_completed, :email, email}, socket) do
    {:noreply,
     socket
     |> assign(step: :code, channel: :email, email: email, dev_otp: nil)
     |> put_flash(:info, "Telegram linked! Check Telegram for your code.")}
  end

  defp tabs_grid_class(1), do: "grid-cols-1"
  defp tabs_grid_class(2), do: "grid-cols-2"
  defp tabs_grid_class(_n), do: "grid-cols-3"

  defp channel_icon(:phone), do: "hero-chat-bubble-left-right"
  defp channel_icon(:telegram), do: "hero-paper-airplane"
  defp channel_icon(:email), do: "hero-envelope"

  defp channel_label(:phone), do: "WhatsApp"
  defp channel_label(:telegram), do: "Telegram"
  defp channel_label(:email), do: "Email"

  # WhatsApp being down still leaves whichever of the other two tabs is
  # actually configured for this deployment-named explicitly rather than a
  # generic "try again later" so the student isn't left guessing there's
  # another way in at all.
  defp whatsapp_unavailable_flash(socket) do
    case socket.assigns.visible_channels -- [:phone] do
      [] ->
        "WhatsApp is temporarily unavailable. Please try again shortly."

      channels ->
        "WhatsApp is temporarily unavailable. Try the #{channels_sentence(channels)} tab instead."
    end
  end

  defp channels_sentence(channels) do
    channels |> Enum.map(&channel_label/1) |> Enum.join(" or ")
  end

  defp request_code_flash(:telegram), do: "Code sent! Check Telegram."
  defp request_code_flash(:whatsapp), do: "Code sent! Check WhatsApp."

  defp request_email_flash(:telegram, _email_enabled?), do: "Code sent! Check Telegram."

  defp request_email_flash(:email, email_enabled?) do
    if email_enabled? do
      "Code sent! Check your inbox."
    else
      "Code generated. Email isn't wired up in this environment, so check the server logs for it."
    end
  end

  defp whatsapp_enabled? do
    Application.get_env(:nurseprep, :otp_sender, NursePrep.Accounts.OtpSender.Log) !=
      NursePrep.Accounts.OtpSender.Log
  end

  defp email_enabled? do
    Application.get_env(:nurseprep, :email_otp_sender, NursePrep.Accounts.EmailOtpSender.Log) !=
      NursePrep.Accounts.EmailOtpSender.Log
  end

  # Surfaces a pointer to the code directly in the UI when no real sender is
  # configured, so login is usable end-to-end before SMTP is wired up. The
  # WhatsApp tab only ever renders when `whatsapp_enabled?/0` is true (see
  # `mount/3`'s `visible_channels`), so there's no equivalent dev-mode gap
  # to cover there, and the Telegram tab always delivers for real once
  # linked-neither needs a clause here.
  defp dev_otp_hint(:email), do: if(email_enabled?(), do: nil, else: "check server logs")
end
