defmodule CaptainHomework.RepairProgressTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.RepairProgress

  test "coordinate changes without fewer defects stop after two unsuccessful repairs" do
    issues = %{"q1" => %{"issue_codes" => ["document_focused"]}}
    first = RepairProgress.update(%{}, 5, issues)
    second = RepairProgress.update(first, 5, issues)
    refute RepairProgress.stalled?(second)
    third = RepairProgress.update(second, 5, issues)
    assert RepairProgress.stalled?(third)
  end

  test "accepting a question or resolving a defect resets the no-progress counter" do
    previous = %{"accepted" => 5, "defects" => 2, "stagnant" => 1}
    issues = %{"q1" => %{"issue_codes" => ["document_focused"]}}
    assert RepairProgress.update(previous, 5, issues)["stagnant"] == 0
    assert RepairProgress.update(previous, 6, issues)["stagnant"] == 0
  end

  test "losing and regaining an accepted question is not progress" do
    issues = %{"q1" => %{"issue_codes" => ["document_focused"]}}
    best = RepairProgress.update(%{}, 5, issues)
    regression = RepairProgress.update(best, 4, issues)
    assert RepairProgress.stalled?(RepairProgress.update(regression, 5, issues))
  end
end
