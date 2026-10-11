defmodule NursePrep.Formatting do
  @moduledoc """
  Small presentation-formatting helpers shared between the web UI and
  WhatsApp text replies, so both channels report the same numbers the same
  way.
  """

  @doc """
  Formats a percentage for display, dropping a trailing `.0` so `10.0`
  reads as `10%` while `74.5` still shows its decimal. `nil` renders as an
  em dash (no data yet).

      iex> NursePrep.Formatting.percent(10.0)
      "10%"
      iex> NursePrep.Formatting.percent(74.5)
      "74.5%"
      iex> NursePrep.Formatting.percent(nil)
      "—"
  """
  def percent(nil), do: "—"

  def percent(value) when is_number(value) do
    if trunc(value) == value do
      "#{trunc(value)}%"
    else
      "#{value}%"
    end
  end

  @doc """
  Formats a kobo amount (Paystack's base unit-1/100th of a Naira) as a
  comma-grouped Naira string, no currency symbol (callers prefix `₦`
  themselves, since some render it outside this string e.g. next to a
  `/month` suffix).

      iex> NursePrep.Formatting.naira(500_000)
      "5,000.00"
      iex> NursePrep.Formatting.naira(50)
      "0.50"
      iex> NursePrep.Formatting.naira(0)
      "0.00"
  """
  def naira(amount_kobo) when is_integer(amount_kobo) do
    naira_amount = :erlang.float_to_binary(amount_kobo / 100, decimals: 2)
    [whole, cents] = String.split(naira_amount, ".")
    group_thousands(whole) <> "." <> cents
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Short relative-time label for admin activity feeds ("5m ago", "3h ago"),
  falling back to a plain date past a week out (a label like "12d ago"
  stops being useful for actually placing an event in time). `nil` renders
  as an em dash-same "no data" convention as `percent/1`.

      iex> now = DateTime.utc_now()
      iex> NursePrep.Formatting.relative_time(now)
      "just now"
      iex> NursePrep.Formatting.relative_time(DateTime.add(now, -300, :second))
      "5m ago"
      iex> NursePrep.Formatting.relative_time(DateTime.add(now, -7200, :second))
      "2h ago"
      iex> NursePrep.Formatting.relative_time(DateTime.add(now, -172_800, :second))
      "2d ago"
      iex> NursePrep.Formatting.relative_time(nil)
      "—"
  """
  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second) |> max(0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%b %d, %Y")
    end
  end
end
