defmodule NursePrep.Evals.AiCleanupEvalTest do
  @moduledoc """
  Quality eval for `AiCleanupWorker`'s OCR-cleanup prompt — shells out to the
  real local Claude Code CLI (see `NursePrep.Questions.LocalClaudeClient`),
  so it costs real money and is excluded from the default `mix test` run
  (see `test/test_helper.exs`) and never part of `mix precommit` or CI.

  Run it explicitly:

      mix test --only eval test/evals/ai_cleanup_eval_test.exs

  Each case is a real OCR-garbled stem pulled from
  `priv/source_data/nursing_questions.docx` ingestion output. Checked two
  ways: the specific known garble must be fixed, and the clinically load-
  bearing term (the thing that determines which answer is correct) must
  survive untouched — a cleanup that "fixes" spelling by changing the
  medical meaning is worse than leaving it alone.
  """
  use ExUnit.Case, async: false

  alias NursePrep.Questions.LocalClaudeClient
  alias NursePrep.Questions.Workers.AiCleanupWorker

  @moduletag :eval
  @moduletag timeout: :timer.minutes(5)

  @pass_rate_threshold 0.8

  @cases [
    %{
      raw:
        "One of me following is an increase in the rate and depth of breathing that exceeds the body's need to remove Carbnndioiidt",
      must_fix: ~w(me Carbnndioiidt),
      must_keep: ~w(breathing)
    },
    %{
      raw: "The presence of interrelated disc in (he cardiac muscles allows it to function as",
      must_fix: ["(he"],
      must_keep: ~w(cardiac muscles)
    },
    %{
      raw: "Calcitomn is secreted by",
      must_fix: ["Calcitomn"],
      must_keep: ["secreted"]
    },
    %{
      raw: "The process of rendering instruments free from an microbes is referred to as",
      must_fix: ["an microbes"],
      must_keep: ~w(instruments referred)
    },
    %{
      raw: "A clinical manifestation indicative of ketoacidesis",
      must_fix: ["ketoacidesis"],
      must_keep: ["clinical", "manifestation"]
    }
  ]

  test "cleaned stems fix known OCR noise without losing the clinical wording" do
    results =
      Enum.map(@cases, fn %{raw: raw, must_fix: must_fix, must_keep: must_keep} ->
        prompt = """
        Raw stem:
        #{raw}

        Subjects/topics (subject_id, topic_id, subject name > topic name):
        (none available in this eval)
        """

        case LocalClaudeClient.ask(prompt, AiCleanupWorker.system_prompt()) do
          {:ok, %{text: text}} ->
            case Jason.decode(strip_fences(text)) do
              {:ok, %{"cleaned_stem" => cleaned}} when is_binary(cleaned) ->
                fixed? = Enum.all?(must_fix, &(not String.contains?(cleaned, &1)))
                kept? = Enum.all?(must_keep, &String.contains?(cleaned, &1))
                %{raw: raw, cleaned: cleaned, pass: fixed? and kept?}

              _ ->
                %{raw: raw, cleaned: nil, pass: false}
            end

          {:error, reason} ->
            %{raw: raw, cleaned: nil, pass: false, error: reason}
        end
      end)

    pass_rate = Enum.count(results, & &1.pass) / length(results)

    failures = Enum.reject(results, & &1.pass)

    assert pass_rate >= @pass_rate_threshold, """
    Cleanup eval pass rate #{Float.round(pass_rate * 100, 1)}% below #{@pass_rate_threshold * 100}% threshold.

    Failures:
    #{Enum.map_join(failures, "\n\n", &inspect(&1, pretty: true))}
    """
  end

  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end
end
