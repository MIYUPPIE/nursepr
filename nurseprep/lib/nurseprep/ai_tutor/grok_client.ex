defmodule NursePrep.AiTutor.GrokClient do
  @moduledoc """
  Thin `Req` wrapper around xAI's OpenAI-compatible chat completions API.
  This is the one place in the app that calls a hosted LLM API directly
  rather than routing through local Claude Code-an explicit, scoped
  exception for the AI tutor specifically, because a WhatsApp bot serving
  many concurrent students needs a networked, multi-tenant LLM backend
  that a local CLI process can't provide.
  """

  @base_url "https://api.x.ai/v1/chat/completions"
  @max_tokens 1024

  @system_prompt """
  You are the NursePrep AI Tutor, a study aid for Nigerian nursing and \
  midwifery students preparing for the NMCN Professional Examination.

  Scope: answer questions about nursing, midwifery, anatomy & physiology, \
  pharmacology, community health, psychiatric nursing, nursing ethics, and \
  related NMCN exam topics. Explain concepts clearly, the way a study \
  partner would.

  Out of scope: general chit-chat, homework in unrelated subjects, and \
  requests to diagnose or give clinical advice about a real patient or the \
  user's own symptoms. Politely decline those and redirect to nursing \
  education topics instead.

  Always make clear you're a study aid, not a substitute for clinical \
  judgment or a real instructor.
  """

  @doc "Sends the full message history (oldest first) and returns the assistant's reply plus token usage."
  def ask(messages) when is_list(messages), do: ask(messages, @system_prompt)

  @doc """
  Same as `ask/1`, with a caller-supplied system prompt instead of the
  tutor persona-used by the AI tutor eval suite's LLM-as-judge grading
  call, which needs Grok scoped to grading a rubric, not the student-facing
  tutor voice. Not called anywhere in the product itself.
  """
  def ask(messages, system_prompt) when is_list(messages) and is_binary(system_prompt) do
    config = Application.fetch_env!(:nurseprep, :xai)

    cond do
      config[:plug] -> do_request(messages, system_prompt, config, plug: config[:plug])
      is_nil(config[:api_key]) -> {:error, :not_configured}
      true -> do_request(messages, system_prompt, config, finch: NursePrep.Finch.Xai)
    end
  end

  defp do_request(messages, system_prompt, config, transport_opts) do
    api_key = config[:api_key] || "test"
    model = config[:model] || "grok-4"

    api_messages =
      [%{"role" => "system", "content" => system_prompt}] ++
        Enum.map(messages, &%{"role" => &1.role, "content" => &1.content})

    req =
      ([
         method: :post,
         url: @base_url,
         headers: [
           {"authorization", "Bearer #{api_key}"}
         ],
         json: %{
           "model" => model,
           "max_tokens" => @max_tokens,
           "messages" => api_messages
         },
         retry: :transient,
         retry_delay: fn attempt -> 50 * (attempt + 1) end,
         max_retries: 3
       ] ++ transport_opts)
      |> Req.new()

    case Req.request(req) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           text: extract_text(body),
           model: body["model"] || model,
           tokens_input: get_in(body, ["usage", "prompt_tokens"]),
           tokens_output: get_in(body, ["usage", "completion_tokens"])
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: content

  defp extract_text(_), do: ""
end
