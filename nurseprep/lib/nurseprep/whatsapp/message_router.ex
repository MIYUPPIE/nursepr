defmodule NursePrep.Whatsapp.MessageRouter do
  @moduledoc """
  Pure parsing of inbound WhatsApp text into a command `Whatsapp.Session`
  acts on. Kept free of GenServer/DB concerns so the parsing rules
  themselves are trivially unit-testable.
  """

  alias NursePrep.Questions

  @type command ::
          {:practice, Questions.Subject.t() | nil}
          | {:answer, String.t()}
          | {:ask, String.t()}
          | :subscribe
          | :help
          | :weak_areas
          | :stats
          | :profile
          | {:leaderboard, :weekly | :all_time}
          | :exam
          | :pause
          | :resume
          | :stop
          | {:unrecognized, String.t()}

  @doc """
  Parses `text` given the session's current `awaiting` state (`:answer` when
  a quiz question is outstanding, `nil` otherwise)-the same text ("2", for
  instance) means something different depending on what we're waiting for.
  """
  @spec route(String.t(), atom()) :: command()
  def route(text, awaiting) do
    normalized = text |> String.trim() |> String.downcase()

    cond do
      awaiting == :answer and answer_like?(normalized) ->
        {:answer, normalized}

      # Checked ahead of every other command so they work no matter what
      # the session is waiting on-mid-quiz, mid-answer, or idle-same as
      # a real "pause"/"stop" button would.
      pause_command?(normalized) ->
        :pause

      resume_command?(normalized) ->
        :resume

      stop_command?(normalized) ->
        :stop

      practice_command?(normalized) ->
        {:practice, extract_subject(normalized)}

      exam_command?(normalized) ->
        :exam

      normalized in ~w(subscribe upgrade pay) ->
        :subscribe

      weak_areas_command?(normalized) ->
        :weak_areas

      stats_command?(normalized) ->
        :stats

      profile_command?(normalized) ->
        :profile

      leaderboard_command?(normalized) ->
        {:leaderboard, leaderboard_scope(normalized)}

      normalized in ~w(hi hello help start menu) ->
        :help

      ask_command?(normalized) and extract_question(text) != "" ->
        {:ask, extract_question(text)}

      true ->
        {:unrecognized, text}
    end
  end

  defp answer_like?(text), do: String.match?(text, ~r/^[a-d]$|^[1-4]$/)

  defp practice_command?(text),
    do: String.starts_with?(text, "practice") or String.starts_with?(text, "quiz")

  defp ask_command?(text), do: String.starts_with?(text, "ask")

  defp exam_command?(text),
    do:
      text in ~w(exam) or String.starts_with?(text, "exam") or
        String.starts_with?(text, "mock exam")

  defp pause_command?(text), do: text in ~w(pause /pause)

  defp resume_command?(text), do: text in ~w(resume /resume continue)

  defp stop_command?(text), do: text in ~w(stop /stop)

  defp weak_areas_command?(text),
    do: text in ~w(weak weakness) or String.starts_with?(text, "weak area")

  defp stats_command?(text), do: text in ~w(stats dashboard status progress analytics)

  defp profile_command?(text), do: text in ~w(profile settings account me)

  defp leaderboard_command?(text),
    do: text in ~w(leaderboard rank ranking ranks) or String.starts_with?(text, "leaderboard")

  defp leaderboard_scope(text) do
    if String.contains?(text, "all time") or String.contains?(text, "all-time"),
      do: :all_time,
      else: :weekly
  end

  defp extract_subject("practice"), do: nil
  defp extract_subject("quiz"), do: nil
  defp extract_subject("practice " <> rest), do: fuzzy_match_subject(String.trim(rest))
  defp extract_subject("quiz " <> rest), do: fuzzy_match_subject(String.trim(rest))
  defp extract_subject(_), do: nil

  # Operates on the original, non-lowercased `text` (unlike every other
  # extractor here) so the question sent to the AI tutor keeps whatever
  # capitalization the student actually typed.
  defp extract_question(text) do
    case Regex.run(~r/^ask\s+(.+)$/is, String.trim(text)) do
      [_, question] -> String.trim(question)
      nil -> ""
    end
  end

  @doc """
  Fuzzy-matches free text against subject names (Jaro distance) since
  WhatsApp users will type "pharm" or "maternal health", not the exact
  subject name. Returns nil (not an error) below the confidence threshold
  so the caller can fall back to an interactive subject list instead of
  guessing wrong.
  """
  def fuzzy_match_subject(text) when text in [nil, ""], do: nil

  def fuzzy_match_subject(text) do
    Questions.list_subjects()
    |> Enum.map(&{&1, String.jaro_distance(String.downcase(&1.name), String.downcase(text))})
    |> Enum.max_by(fn {_subject, score} -> score end, fn -> nil end)
    |> case do
      {subject, score} when score >= 0.75 -> subject
      _ -> nil
    end
  end

  @doc "Normalizes an answer reply (\"a\"/\"1\" etc.) to an option label (\"A\"-\"D\")."
  def answer_to_label("1"), do: "A"
  def answer_to_label("2"), do: "B"
  def answer_to_label("3"), do: "C"
  def answer_to_label("4"), do: "D"
  def answer_to_label(letter), do: String.upcase(letter)
end
