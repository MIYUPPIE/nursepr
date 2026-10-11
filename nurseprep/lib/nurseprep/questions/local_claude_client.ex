defmodule NursePrep.Questions.LocalClaudeClient do
  @moduledoc """
  Shells out to a local Claude Code invocation (`npx @anthropic-ai/claude-code
  -p ...`) rather than calling a hosted LLM API directly. Per this project's
  standing policy, new LLM calls route through local Claude Code unless
  explicitly told otherwise-`AiTutor.GrokClient` is the one documented,
  scoped exception (a multi-tenant WhatsApp bot needs a networked backend;
  this doesn't, it's an admin-triggered batch job).

  Deliberately does not pass `--model`: this project's policy is "best
  available model by default, no silent downgrade for cost" — the caller's
  session picks the model, same as every other Claude Code invocation.
  `--disallowedTools "*"` keeps each call a single text-in/text-out
  completion (no file/bash access needed for a cleanup suggestion), and
  `--system-prompt` fully replaces the default CLI persona with the
  caller-supplied one instead of appending to it.
  """
  @behaviour NursePrep.Questions.LocalClaudeClient.Behaviour

  @timeout_seconds 120

  @impl true
  def ask(prompt, system_prompt) when is_binary(prompt) and is_binary(system_prompt) do
    args = [
      "--yes",
      "@anthropic-ai/claude-code",
      "-p",
      prompt,
      "--output-format",
      "json",
      "--system-prompt",
      system_prompt,
      "--disallowedTools",
      "*"
    ]

    case System.cmd("timeout", [to_string(@timeout_seconds), "npx" | args],
           stderr_to_stdout: false
         ) do
      {output, 0} -> parse_result(output)
      {output, status} -> {:error, {:exit_status, status, String.slice(output, 0, 500)}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp parse_result(output) do
    with {:ok, %{"is_error" => false, "result" => text}} <- Jason.decode(output) do
      {:ok, %{text: text}}
    else
      {:ok, %{"is_error" => true, "result" => reason}} -> {:error, {:cli_error, reason}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, {:unparseable_output, reason}}
    end
  end
end
