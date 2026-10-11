defmodule NursePrepWeb.AiTutorLive do
  @moduledoc """
  Web chat with the AI tutor.

  Non-streaming (one request, one reply) for now. The "thinking..."
  indicator via `start_async` keeps the request from blocking the
  LiveView socket while the AI request is being processed.
  """

  use NursePrepWeb, :live_view

  alias NursePrep.AiTutor

  @suggested_questions [
    "What's the difference between Type 1 and Type 2 diabetes?",
    "Walk me through the stages of labour.",
    "What are the danger signs of pre-eclampsia?",
    "Explain the nursing process (ADPIE)."
  ]

  @markdown_extension [
    table: true,
    strikethrough: true,
    autolink: true
  ]

  @markdown_render [
    hardbreaks: true
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.student
      flash={@flash}
      current_scope={@current_scope}
      active={:tutor}
      container_class="w-full max-w-none px-2 sm:px-4 lg:px-6 2xl:px-8"
    >
      <div class="w-full max-w-none">
        <!-- Header -->
        <.header icon="hero-academic-cap">
          AI Tutor
          <:subtitle>
            Ask anything about nursing/midwifery topics - this is a study aid, not clinical advice.
          </:subtitle>
        </.header>

        <!-- AI Tutor Card -->
        <div class="
            card
            bg-base-100
            border
            border-base-300
            mt-4
            overflow-hidden
            flex
            flex-col
            w-full
            max-w-none
            min-w-0
            min-h-[36rem]
            sm:min-h-[40rem]
            lg:min-h-[44rem]
          ">
          <!-- Chat History -->
          <div
            id="chat-history"
            phx-hook=".ChatScroll"
            class="
              flex
              flex-col
              gap-4
              p-4
              sm:p-6
              lg:p-8
              flex-1
              min-h-0
              overflow-y-auto
              w-full
            "
          >
            <!-- Empty State -->
            <div
              :if={@messages == [] and !@thinking}
              class="
                m-auto
                flex
                max-w-sm
                sm:max-w-md
                lg:max-w-lg
                flex-col
                items-center
                gap-4
                text-center
              "
            >
              <div class="
                  flex
                  size-12
                  items-center
                  justify-center
                  rounded-full
                  bg-primary/10
                  text-primary
                ">
                <.icon
                  name="hero-academic-cap"
                  class="size-6"
                />
              </div>

              <div>
                <p class="font-semibold text-lg">
                  Ask your AI tutor anything
                </p>

                <p class="text-sm text-base-content/60 mt-1">
                  Nursing, midwifery, pharmacology, community health -
                  try a question below or type your own.
                </p>
              </div>

              <!-- Suggested Questions -->
              <div class="flex flex-wrap justify-center gap-2">
                <button
                  :for={q <- @suggested_questions}
                  type="button"
                  phx-click="ask_suggested"
                  phx-value-question={q}
                  class="btn btn-sm btn-soft btn-primary rounded-full"
                >
                  {q}
                </button>
              </div>
            </div>

            <!-- Messages -->
            <div
              :for={m <- @messages}
              class={[
                "chat w-full",
                if(m.role == "user", do: "chat-end", else: "chat-start")
              ]}
            >
              <!-- Avatar -->
              <div class="chat-image">
                <.chat_avatar role={m.role} />
              </div>

              <!-- Message -->
              <div class={[
                "chat-bubble",
                "max-w-[95%]",
                "sm:max-w-[85%]",
                "lg:max-w-[75%]",
                "2xl:max-w-[65%]",
                if(
                  m.role == "user",
                  do: "chat-bubble-primary",
                  else: "chat-markdown"
                )
              ]}>
                <%= if m.role == "user" do %>
                  {m.content}
                <% else %>
                  {render_markdown(m.content)}
                <% end %>
              </div>
            </div>

            <!-- Thinking Indicator -->
            <div
              :if={@thinking}
              class="chat chat-start"
            >
              <div class="chat-image">
                <.chat_avatar role="assistant" />
              </div>

              <div class="chat-bubble">
                <span class="loading loading-dots loading-sm"></span>
              </div>
            </div>
          </div>

          <!-- Input Area -->
          <div class="
              border-t
              border-base-300
              p-3
              sm:p-4
              lg:p-5
              w-full
              bg-base-100
            ">
            <!-- Weak Areas Button -->
            <.button
              type="button"
              phx-click="explain_weak_areas"
              disabled={@thinking}
              class="btn-sm btn-ghost mb-3"
            >
              <.icon
                name="hero-light-bulb"
                class="size-4"
              /> Explain my weak areas
            </.button>

            <!-- Chat Form -->
            <.form
              for={@form}
              phx-submit="ask"
              class="
                flex
                w-full
                items-center
                gap-2
              "
            >
              <!-- Input Wrapper -->
              <div class="flex-1 min-w-0 w-full">
                <.input
                  field={@form[:question]}
                  type="text"
                  placeholder="Ask a question..."
                  class="
                    input
                    input-bordered
                    w-full
                    h-12
                    sm:h-14
                    text-base
                    sm:text-lg
                    px-4
                    sm:px-5
                  "
                  disabled={@thinking}
                  autocomplete="off"
                />
              </div>

              <!-- Send Button -->
              <.button
                variant="primary"
                disabled={@thinking}
                class="
                  h-12
                  sm:h-14
                  px-4
                  sm:px-6
                  shrink-0
                "
              >
                <.icon
                  name="hero-paper-airplane"
                  class="size-5"
                />

                <span class="hidden sm:inline">
                  Send
                </span>
              </.button>
            </.form>
          </div>
        </div>
      </div>

      <!-- Chat Scroll Hook -->
      <script
        :type={Phoenix.LiveView.ColocatedHook}
        name=".ChatScroll"
      >
        export default {
          mounted() {
            this.scrollToBottom()
          },

          updated() {
            this.scrollToBottom()
          },

          scrollToBottom() {
            this.el.scrollTop = this.el.scrollHeight
          }
        }
      </script>
    </Layouts.student>
    """
  end

  attr :role, :string, required: true

  defp chat_avatar(assigns) do
    ~H"""
    <div class={[
      "flex size-8 items-center justify-center rounded-full",
      if(
        @role == "user",
        do: "bg-base-300 text-base-content/70",
        else: "bg-primary/10 text-primary"
      )
    ]}>
      <.icon
        name={
          if @role == "user",
            do: "hero-user",
            else: "hero-academic-cap"
        }
        class="size-4"
      />
    </div>
    """
  end

  defp render_markdown(text) do
    text
    |> MDEx.to_html!(
      extension: @markdown_extension,
      render: @markdown_render
    )
    |> raw()
  end

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user

    messages = AiTutor.history(user, "web")

    socket =
      socket
      |> assign(
        messages: messages,
        thinking: false,
        suggested_questions: @suggested_questions
      )
      |> assign(form: to_form(%{"question" => ""}, as: "chat"))

    socket =
      if params["explain"] == "weak_areas" and connected?(socket) do
        start_weak_areas_explanation(
          socket,
          user
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "explain_weak_areas",
        _params,
        socket
      ) do
    {:noreply,
     start_weak_areas_explanation(
       socket,
       socket.assigns.current_scope.user
     )}
  end

  def handle_event(
        "ask_suggested",
        %{"question" => question},
        socket
      ) do
    handle_event(
      "ask",
      %{
        "chat" => %{
          "question" => question
        }
      },
      socket
    )
  end

  def handle_event(
        "ask",
        %{
          "chat" => %{
            "question" => question
          }
        },
        socket
      ) do
    question = String.trim(question)

    if question == "" do
      {:noreply, socket}
    else
      user = socket.assigns.current_scope.user

      optimistic =
        socket.assigns.messages ++
          [
            %{
              role: "user",
              content: question
            }
          ]

      socket =
        socket
        |> assign(
          messages: optimistic,
          thinking: true,
          form: to_form(%{"question" => ""}, as: "chat")
        )
        |> start_async(
          :ask_tutor,
          fn ->
            AiTutor.ask(
              user,
              "web",
              question
            )
          end
        )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        :ask_tutor,
        {:ok, {:ok, _reply}},
        socket
      ) do
    user = socket.assigns.current_scope.user

    {:noreply,
     assign(
       socket,
       messages: AiTutor.history(user, "web"),
       thinking: false
     )}
  end

  def handle_async(
        :ask_tutor,
        {:ok, {:error, :rate_limited}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(thinking: false)
     |> put_flash(
       :error,
       "You've reached the hourly limit for tutor questions - please try again in a bit."
     )}
  end

  def handle_async(
        :ask_tutor,
        {:ok, {:error, :subscription_required}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(thinking: false)
     |> put_flash(
       :error,
       "The AI tutor is a Premium feature. Upgrade under Subscription to unlock it."
     )}
  end

  def handle_async(
        :ask_tutor,
        {:ok, {:error, _reason}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(thinking: false)
     |> put_flash(
       :error,
       "Sorry, the tutor is unavailable right now. Please try again shortly."
     )}
  end

  def handle_async(
        :ask_tutor,
        {:exit, _reason},
        socket
      ) do
    {:noreply,
     socket
     |> assign(thinking: false)
     |> put_flash(
       :error,
       "Sorry, something went wrong. Please try again."
     )}
  end

  defp start_weak_areas_explanation(
         socket,
         user
       ) do
    socket
    |> assign(thinking: true)
    |> start_async(
      :ask_tutor,
      fn ->
        AiTutor.explain_weak_areas(
          user,
          "web"
        )
      end
    )
  end
end
