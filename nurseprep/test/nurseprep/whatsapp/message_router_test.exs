defmodule NursePrep.Whatsapp.MessageRouterTest do
  use NursePrep.DataCase, async: true

  import NursePrep.Factory

  alias NursePrep.Whatsapp.MessageRouter

  describe "route/2" do
    test "routes bare 'practice' to a subject-less practice command" do
      assert MessageRouter.route("practice", nil) == {:practice, nil}
      assert MessageRouter.route("Practice", nil) == {:practice, nil}
    end

    test "routes 'quiz' as a synonym for 'practice'" do
      assert MessageRouter.route("quiz", nil) == {:practice, nil}
      assert MessageRouter.route("Quiz", nil) == {:practice, nil}
    end

    test "routes 'practice <subject>' with a fuzzy-matched subject" do
      subject = insert(:subject, name: "Pharmacology")
      assert {:practice, matched} = MessageRouter.route("practice pharmacology", nil)
      assert matched.id == subject.id
    end

    test "routes 'quiz <subject>' with a fuzzy-matched subject, same as 'practice <subject>'" do
      subject = insert(:subject, name: "Pharmacology")
      assert {:practice, matched} = MessageRouter.route("quiz pharmacology", nil)
      assert matched.id == subject.id
    end

    test "falls back to nil subject when nothing matches confidently" do
      insert(:subject, name: "Pharmacology")
      assert MessageRouter.route("practice something totally unrelated", nil) == {:practice, nil}
    end

    test "routes a letter or digit reply as an answer only while awaiting one" do
      assert MessageRouter.route("b", :answer) == {:answer, "b"}
      assert MessageRouter.route("2", :answer) == {:answer, "2"}
      refute MessageRouter.route("b", nil) == {:answer, "b"}
    end

    test "routes subscribe/upgrade/pay keywords" do
      assert MessageRouter.route("subscribe", nil) == :subscribe
      assert MessageRouter.route("Upgrade", nil) == :subscribe
    end

    test "routes greetings to help" do
      assert MessageRouter.route("hi", nil) == :help
      assert MessageRouter.route("Hello", nil) == :help
    end

    test "routes weak-area requests" do
      assert MessageRouter.route("weak areas", nil) == :weak_areas
      assert MessageRouter.route("weak", nil) == :weak_areas
      assert MessageRouter.route("Weakness", nil) == :weak_areas
    end

    test "routes exam requests" do
      assert MessageRouter.route("exam", nil) == :exam
      assert MessageRouter.route("Exam", nil) == :exam
      assert MessageRouter.route("exam now", nil) == :exam
      assert MessageRouter.route("mock exam", nil) == :exam
      assert MessageRouter.route("Mock Exam", nil) == :exam
    end

    test "routes stats/dashboard requests" do
      assert MessageRouter.route("stats", nil) == :stats
      assert MessageRouter.route("dashboard", nil) == :stats
      assert MessageRouter.route("Status", nil) == :stats
      assert MessageRouter.route("progress", nil) == :stats
      assert MessageRouter.route("analytics", nil) == :stats
    end

    test "routes profile requests" do
      assert MessageRouter.route("profile", nil) == :profile
      assert MessageRouter.route("Settings", nil) == :profile
      assert MessageRouter.route("account", nil) == :profile
      assert MessageRouter.route("me", nil) == :profile
    end

    test "routes leaderboard requests, defaulting to weekly scope" do
      assert MessageRouter.route("leaderboard", nil) == {:leaderboard, :weekly}
      assert MessageRouter.route("rank", nil) == {:leaderboard, :weekly}
      assert MessageRouter.route("leaderboard all time", nil) == {:leaderboard, :all_time}
      assert MessageRouter.route("Leaderboard All-Time", nil) == {:leaderboard, :all_time}
    end

    test "routes pause/resume/stop, with and without a leading slash" do
      assert MessageRouter.route("pause", nil) == :pause
      assert MessageRouter.route("/pause", nil) == :pause
      assert MessageRouter.route("Pause", nil) == :pause

      assert MessageRouter.route("resume", nil) == :resume
      assert MessageRouter.route("/resume", nil) == :resume
      assert MessageRouter.route("continue", nil) == :resume

      assert MessageRouter.route("stop", nil) == :stop
      assert MessageRouter.route("/stop", nil) == :stop
      assert MessageRouter.route("Stop", nil) == :stop
    end

    test "pause/resume/stop take priority over a mid-quiz answer reply" do
      assert MessageRouter.route("stop", :answer) == :stop
      assert MessageRouter.route("pause", :answer) == :pause
      assert MessageRouter.route("resume", :answer) == :resume
    end

    test "falls back to unrecognized" do
      assert MessageRouter.route("what is the capital of Nigeria", nil) ==
               {:unrecognized, "what is the capital of Nigeria"}
    end

    test "routes 'ask <question>' explicitly to the AI tutor, preserving original casing" do
      assert MessageRouter.route("ask What is Beneficence?", nil) ==
               {:ask, "What is Beneficence?"}

      assert MessageRouter.route("Ask what is PHC", nil) == {:ask, "what is PHC"}
    end

    test "bare 'ask' with no question falls back to unrecognized rather than an empty ask" do
      assert MessageRouter.route("ask", nil) == {:unrecognized, "ask"}
      assert MessageRouter.route("ask   ", nil) == {:unrecognized, "ask   "}
    end
  end

  describe "answer_to_label/1" do
    test "maps digits and letters to option labels" do
      assert MessageRouter.answer_to_label("1") == "A"
      assert MessageRouter.answer_to_label("4") == "D"
      assert MessageRouter.answer_to_label("c") == "C"
    end
  end
end
