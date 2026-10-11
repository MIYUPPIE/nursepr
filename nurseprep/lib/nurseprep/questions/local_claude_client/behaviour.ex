defmodule NursePrep.Questions.LocalClaudeClient.Behaviour do
  @moduledoc "Contract for `LocalClaudeClient`, so `AiCleanupWorker` tests can Mox-mock it instead of shelling out for real."

  @callback ask(prompt :: String.t(), system_prompt :: String.t()) ::
              {:ok, %{text: String.t()}} | {:error, term()}
end
