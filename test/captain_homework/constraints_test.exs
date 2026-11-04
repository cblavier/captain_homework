defmodule CaptainHomework.ConstraintsTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{Constraints, Plan}

  @pages [%{id: "course", kind: "lesson"}, %{id: "resource", kind: "resource"}]

  test "formats constrain capabilities without prescribing category counts" do
    assert Constraints.compatible?("long", "direct", "knowledge", @pages)
    assert Constraints.compatible?("long", "developed", "knowledge", @pages)
    refute Constraints.compatible?("reading", "short", "knowledge", @pages)
    assert Constraints.compatible?("mcq", "direct", "knowledge", @pages)
    refute Constraints.compatible?("mcq", "developed", "knowledge", @pages)
    refute Constraints.compatible?("long", "direct", "knowledge", [List.last(@pages)])
  end

  test "fingerprints depend on source content and not derived caches or query order" do
    lesson = %{subject: "svt", title: "Cellule"}

    assert Plan.fingerprint(lesson, @pages, []) ==
             Plan.fingerprint(lesson, Enum.reverse(@pages), [])

    cached = Enum.map(@pages, &Map.put(&1, :catalogue_hash, "computed later"))
    assert Plan.fingerprint(lesson, @pages, []) == Plan.fingerprint(lesson, cached, [])

    refute Plan.fingerprint(lesson, @pages, []) ==
             Plan.fingerprint(lesson, [Map.put(hd(@pages), :text, "Updated")], [])
  end
end
