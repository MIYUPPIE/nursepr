defmodule NursePrep.Whatsapp.EvolutionClient do
  @moduledoc """
  Thin `Req`-based wrapper around Evolution API's send endpoints. Reads
  `base_url`/`instance`/`api_key` from `config :nurseprep, :evolution_api` at
  call time (not compile time) so tests can stub with `Req.Test` and real
  credentials can be dropped into env config later with no code changes.

  Quiz questions are sent as plain numbered text (`send_text/2`) rather than
  Evolution's interactive buttons/lists-WhatsApp Business API's interactive
  message support has historically been the flakiest, most
  version-sensitive part of the platform, and a plain "reply 1-4" text
  message works identically across every WhatsApp client. `send_buttons/3`
  and `send_list/3` are still implemented per Evolution API's documented
  contract for anything that later wants them, but the quiz flow itself
  deliberately doesn't depend on them.
  """

  @behaviour NursePrep.Whatsapp.EvolutionClient.Behaviour

  @impl true
  def send_text(phone, text) do
    request(:post, "/message/sendText/#{instance()}", json: %{"number" => phone, "text" => text})
  end

  @impl true
  def send_buttons(phone, text, buttons) when is_list(buttons) do
    body = %{
      "number" => phone,
      "title" => text,
      "buttons" =>
        Enum.map(buttons, fn {id, label} ->
          %{"buttonId" => id, "buttonText" => %{"displayText" => label}}
        end)
    }

    request(:post, "/message/sendButtons/#{instance()}", json: body)
  end

  @impl true
  def send_list(phone, text, rows) when is_list(rows) do
    body = %{
      "number" => phone,
      "title" => text,
      "sections" => [
        %{
          "rows" => Enum.map(rows, fn {id, title} -> %{"rowId" => id, "title" => title} end)
        }
      ]
    }

    request(:post, "/message/sendList/#{instance()}", json: body)
  end

  @impl true
  def connection_state do
    case request(:get, "/instance/connectionState/#{instance()}", []) do
      {:ok, %{"instance" => %{"state" => state}}} when is_binary(state) -> {:ok, state}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, path, opts) do
    config = Application.fetch_env!(:nurseprep, :evolution_api)

    cond do
      # Test-only escape hatch: `plug: {Req.Test, Name}` in config routes
      # through Req.Test's stub/mock ownership model instead of real Finch,
      # without requiring real base_url/api_key values to be configured.
      config[:plug] ->
        do_request(method, path, opts, config, plug: config[:plug])

      is_nil(config[:base_url]) or is_nil(config[:api_key]) ->
        {:error, :not_configured}

      true ->
        do_request(method, path, opts, config, finch: [name: NursePrep.Finch.Evolution])
    end
  end

  defp do_request(method, path, opts, config, transport_opts) do
    req =
      ([
         method: method,
         base_url: config[:base_url] || "http://evolution.test",
         url: path,
         headers: [{"apikey", config[:api_key] || "test"}],
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

  defp instance, do: Application.fetch_env!(:nurseprep, :evolution_api)[:instance]
end
