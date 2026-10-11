defmodule NursePrep.AiTutorFixtures do
  @moduledoc """
  Points `:nurseprep, :xai` at `Req.Test` for the calling test and restores
  the previous config on exit.

  `Application.put_env/3` is process-global, not scoped to a test-every
  call site that mutated `:xai` directly and skipped the reset left it
  permanently pointed at `Req.Test` for the rest of that `mix test` run.
  Any later, unrelated test that triggered a real Grok call without its
  own stub then crashed with "cannot find mock/stub", intermittently and
  dependent on random test order, which made it genuinely hard to pin
  down. Use this instead of inlining `Application.put_env(:nurseprep, :xai, ...)`.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Stubs `:nurseprep, :xai` to route through `Req.Test` for `NursePrep.AiTutor.GrokClient`."
  def stub_xai! do
    previous = Application.get_env(:nurseprep, :xai)

    Application.put_env(:nurseprep, :xai,
      api_key: "test",
      model: "grok-4",
      plug: {Req.Test, NursePrep.AiTutor.GrokClient}
    )

    on_exit(fn -> Application.put_env(:nurseprep, :xai, previous) end)
  end
end
