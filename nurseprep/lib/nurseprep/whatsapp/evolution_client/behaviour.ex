defmodule NursePrep.Whatsapp.EvolutionClient.Behaviour do
  @moduledoc "Contract for `EvolutionClient`, so `Whatsapp.Session` tests can Mox-mock it instead of hitting real HTTP."

  @type phone :: String.t()
  @type result :: {:ok, term()} | {:error, term()}

  @callback send_text(phone, String.t()) :: result
  @callback send_buttons(phone, String.t(), [{String.t(), String.t()}]) :: result
  @callback send_list(phone, String.t(), [{String.t(), String.t()}]) :: result
  @callback connection_state() :: {:ok, String.t()} | {:error, term()}
end
