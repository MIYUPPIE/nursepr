defmodule NursePrep.Factory do
  @moduledoc "ExMachina factories. Extended as each context lands its schemas."

  use ExMachina.Ecto, repo: NursePrep.Repo

  alias NursePrep.Questions.{Subject, Topic, Question, Option}
  alias NursePrep.Subscriptions.{Subscription, Payment}
  alias NursePrep.Accounts.Profile

  def subject_factory do
    %Subject{
      name: sequence(:name, &"Subject #{&1}"),
      slug: sequence(:slug, &"subject-#{&1}")
    }
  end

  def topic_factory do
    %Topic{
      name: sequence(:name, &"Topic #{&1}"),
      slug: sequence(:slug, &"topic-#{&1}"),
      subject: build(:subject)
    }
  end

  def question_factory do
    %Question{
      stem: sequence(:stem, &"Sample question stem #{&1}?"),
      question_type: "mcq",
      status: "published",
      published_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  def option_factory do
    %Option{
      label: sequence(:label, ["A", "B", "C", "D"]),
      body: sequence(:body, &"Option text #{&1}"),
      is_correct: false,
      position: sequence(:position, & &1),
      question: build(:question)
    }
  end

  def subscription_factory do
    %Subscription{
      plan: "premium_monthly",
      status: "pending"
    }
  end

  def payment_factory do
    %Payment{
      paystack_reference: sequence(:paystack_reference, &"ref-#{&1}"),
      amount_kobo: 500_000,
      currency: "NGN",
      status: "pending"
    }
  end

  @doc "Named `profile_for` (not `profile`) since a real `user:` (from AccountsFixtures) must always be passed explicitly-there's no factory-built default user to fall back to."
  def profile_for_factory do
    %Profile{
      full_name: sequence(:full_name, &"Student #{&1}"),
      leaderboard_opt_in: true
    }
  end

  @doc """
  Inserts a published MCQ question with 4 options (B correct), overriding
  question attrs as needed. Not an ExMachina factory (`build/1` would double
  as a side-effecting insert, which defeats build/insert separation)-call
  this directly instead of via `insert(:question_with_options, ...)`.
  """
  def insert_question_with_options(question_attrs \\ []) do
    question = insert(:question, question_attrs)

    options =
      ["A", "B", "C", "D"]
      |> Enum.with_index(1)
      |> Enum.map(fn {label, position} ->
        insert(:option,
          question: question,
          label: label,
          position: position,
          is_correct: label == "B"
        )
      end)

    %{question | options: options}
  end

  @doc """
  Gives `user` an active, unexpired subscription — Premium features (mock
  exams, AI tutor) gate on `Subscriptions.active?/1`, so any test driving
  one of those paths needs this first. Not a plain `insert(:subscription,
  ...)` call site by site since `status: "active"` alone isn't enough —
  `active?/1` also checks `current_period_end` is in the future.
  """
  def subscribe!(user) do
    period_end = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
    insert(:subscription, user: user, status: "active", current_period_end: period_end)
  end
end
