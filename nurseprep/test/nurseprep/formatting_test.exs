defmodule NursePrep.FormattingTest do
  use ExUnit.Case, async: true
  doctest NursePrep.Formatting

  alias NursePrep.Formatting

  describe "percent/1" do
    test "drops a trailing .0 for whole-number floats" do
      assert Formatting.percent(10.0) == "10%"
      assert Formatting.percent(100.0) == "100%"
      assert Formatting.percent(0.0) == "0%"
    end

    test "keeps a meaningful decimal" do
      assert Formatting.percent(74.5) == "74.5%"
      assert Formatting.percent(66.7) == "66.7%"
    end

    test "renders plain integers as-is" do
      assert Formatting.percent(82) == "82%"
      assert Formatting.percent(0) == "0%"
    end

    test "renders nil as an em dash" do
      assert Formatting.percent(nil) == "—"
    end
  end

  describe "naira/1" do
    test "groups thousands and keeps two decimal places" do
      assert Formatting.naira(500_000) == "5,000.00"
      assert Formatting.naira(1_234_567_890) == "12,345,678.90"
    end

    test "handles sub-hundred-thousand amounts without a spurious comma" do
      assert Formatting.naira(50) == "0.50"
      assert Formatting.naira(0) == "0.00"
    end
  end

  describe "relative_time/1" do
    test "renders nil as an em dash" do
      assert Formatting.relative_time(nil) == "—"
    end

    test "just under a minute reads as just now" do
      at = DateTime.utc_now() |> DateTime.add(-59, :second)
      assert Formatting.relative_time(at) == "just now"
    end

    test "minutes, hours, and days ago" do
      now = DateTime.utc_now()
      assert Formatting.relative_time(DateTime.add(now, -90, :second)) == "1m ago"
      assert Formatting.relative_time(DateTime.add(now, -3600, :second)) == "1h ago"
      assert Formatting.relative_time(DateTime.add(now, -86_400, :second)) == "1d ago"
    end

    test "falls back to a plain date a week or more out" do
      at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      assert Formatting.relative_time(at) == Calendar.strftime(at, "%b %d, %Y")
    end
  end
end
