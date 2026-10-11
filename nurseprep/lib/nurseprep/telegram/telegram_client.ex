defmodule NursePrep.Telegram.TelegramClient do
  @moduledoc """
  Thin `Req`-based wrapper around Telegram's Bot API. Reads
  `bot_token`/`base_url` from `config :nurseprep, :telegram_api` at call
  time (not compile time) so tests can stub with `Req.Test` and a real
  bot token can be dropped into env config later with no code changes -
  same pattern as `Whatsapp.EvolutionClient`.

  Sends plain text, no `parse_mode`: Telegram's Markdown/MarkdownV2 modes
  reject the entire message with a 400 on any unescaped special character,
  and AI-tutor replies plus ingested question stems were never written
  with Telegram's escaping rules in mind. A stray literal `*` or `_`
  showing up in a message is a cosmetic cost; a silently-dropped message
  is not.
  """

  @behaviour NursePrep.Telegram.TelegramClient.Behaviour

  @impl true
  def send_text(chat_id, text) when is_integer(chat_id) do
    request("/sendMessage", json: %{"chat_id" => chat_id, "text" => text})
  end

  defp request(path, opts) do
    config = Application.fetch_env!(:nurseprep, :telegram_api)

    cond do
      config[:plug] ->
        do_request(path, opts, config, plug: config[:plug])

      is_nil(config[:bot_token]) ->
        {:error, :not_configured}

      true ->
        do_request(path, opts, config, finch: [name: NursePrep.Finch.Telegram])
    end
  end

  defp do_request(path, opts, config, transport_opts) do
    token = config[:bot_token] || "test"

    req =
      ([
         method: :post,
         base_url: config[:base_url] || "https://api.telegram.org/bot#{token}",
         url: path,
         retry: :transient,
         retry_delay: fn attempt -> 50 * (attempt + 1) end,
         max_retries: 2
       ] ++ transport_opts)
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp.body}
      {:ok, resp} -> {:error, {:http_error, resp.status, resp.body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
