defmodule NursePrepWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use NursePrepWeb, :html

  embed_templates "page_html/*"

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(n), do: "#{n}"
end
