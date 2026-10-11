ExUnit.start()

# `:eval` tests hit the real xAI (Grok) API (billed, non-deterministic quality
# checks) and are deliberately excluded from the default gate suite-run
# them explicitly with `mix test --only eval test/evals`, never as part of
# `mix precommit` or CI.
ExUnit.configure(exclude: [:eval])

Ecto.Adapters.SQL.Sandbox.mode(NursePrep.Repo, :manual)
:ets.new(:otp_sender_test_codes, [:set, :public, :named_table])
:ets.new(:email_otp_sender_test_codes, [:set, :public, :named_table])
:ets.new(:whatsapp_alert_sender_test_reasons, [:set, :public, :named_table])

Mox.defmock(NursePrep.Whatsapp.EvolutionClientMock,
  for: NursePrep.Whatsapp.EvolutionClient.Behaviour
)

Mox.defmock(NursePrep.Questions.LocalClaudeClientMock,
  for: NursePrep.Questions.LocalClaudeClient.Behaviour
)

Mox.defmock(NursePrep.Telegram.TelegramClientMock,
  for: NursePrep.Telegram.TelegramClient.Behaviour
)
