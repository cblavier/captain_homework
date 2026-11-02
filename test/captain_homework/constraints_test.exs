defmodule CaptainHomework.ConstraintsTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{Constraints, Plan}

  @pages [%{id: "course", kind: "lesson"}, %{id: "resource", kind: "resource"}]

  test "full formats satisfy both targets" do
    assert Constraints.targets(10, ["long"], @pages) == %{
             effort: %{"direct" => 4, "short" => 4, "developed" => 2},
             basis: %{"knowledge" => 5, "document" => 5}
           }
  end

  test "reading and mcq cannot demand more memorized answers than direct answers" do
    targets = Constraints.targets(10, ["reading", "mcq"], @pages)
    assert targets.basis["knowledge"] <= targets.effort["direct"]
    assert Enum.sum(Map.values(targets.effort)) == 10
    refute Constraints.compatible?("reading", "short", "knowledge", @pages)
    assert Constraints.compatible?("mcq", "direct", "knowledge", @pages)
  end

  test "single response formats never force incompatible writing" do
    assert Constraints.targets(10, ["definition"], @pages).effort == %{
             "direct" => 10,
             "short" => 0,
             "developed" => 0
           }

    assert Constraints.targets(10, ["reading"], @pages).basis == %{
             "knowledge" => 0,
             "document" => 10
           }

    assert Constraints.targets(10, ["long"], [List.last(@pages)]).basis == %{
             "knowledge" => 0,
             "document" => 10
           }
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

  test "fixed slots satisfy joint targets and preserve kept IDs without collisions" do
    for count <- [3, 10, 30],
        types <- [["reading", "mcq"], ["reading"], ["definition"], ["long"]] do
      targets = Constraints.targets(count, types, @pages)
      slots = Constraints.slots(count, types, @pages, [%{"plan_id" => "q2"}])
      assert length(slots) == count
      assert length(Enum.uniq_by(slots, & &1["id"])) == count
      assert hd(slots)["id"] == "q2"

      assert Enum.frequencies_by(slots, & &1["answer_basis"]) ==
               Map.reject(targets.basis, fn {_, value} -> value == 0 end)

      assert Enum.frequencies_by(slots, & &1["response_effort"]) ==
               Map.reject(targets.effort, fn {_, value} -> value == 0 end)

      questions = Enum.map(slots, &Map.put(&1, "type", hd(&1["allowed_types"])))
      assert :ok = Constraints.validate_slots(questions, slots)
    end
  end

  test "a question cannot swap its reserved category with another slot" do
    slots = Constraints.slots(10, ["long"], @pages)
    questions = Enum.map(slots, &Map.put(&1, "type", "long"))
    [first | rest] = questions
    changed = Map.put(first, "response_effort", "developed")
    assert {:error, reason} = Constraints.validate_slots([changed | rest], slots)
    assert reason =~ "q1"
  end
end
