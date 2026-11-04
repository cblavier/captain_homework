defmodule CaptainHomework.Exams.RepairProgress do
  @moduledoc "Stops a repair loop that neither accepts questions nor reduces review defects."
  @limit 2

  def update(previous, accepted_count, diagnostics) do
    defects =
      Enum.reduce(diagnostics, 0, fn {_, value}, n ->
        n + max(length(value["issue_codes"] || []), 1)
      end)

    score = {accepted_count, -defects}
    previous_score = {previous["accepted"] || -1, -(previous["defects"] || 0)}

    if score > previous_score do
      %{"accepted" => accepted_count, "defects" => defects, "stagnant" => 0}
    else
      Map.put(previous, "stagnant", (previous["stagnant"] || 0) + 1)
    end
  end

  def stalled?(progress), do: (progress["stagnant"] || 0) >= @limit
end
