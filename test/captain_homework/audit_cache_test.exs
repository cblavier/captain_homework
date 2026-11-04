defmodule CaptainHomework.AuditCacheTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.AuditCache

  test "unchanged documents retain their review, changed context only checks knowledge exposure" do
    knowledge = question("q1", "knowledge")
    document = question("q2", "document")
    changed = put_in(question("q3", "document"), ["text"], "Nouveau document")
    original = [knowledge, document, question("q3", "document")]
    cache = AuditCache.record(original, original, "sources")

    assert {[^changed], [^knowledge], [^document]} =
             AuditCache.select([knowledge, document, changed], cache, "sources")
  end

  test "changing a crop, rubric, or source invalidates its semantic review" do
    q = question("q1", "document")
    cache = AuditCache.record([q], [q], "sources")
    assert {[], [], [^q]} = AuditCache.select([q], cache, "sources")

    for changed <- [
          Map.put(q, "image_regions", [%{"x" => 5}]),
          Map.put(q, "rubric", "Deux raisons")
        ] do
      assert {[^changed], [], []} = AuditCache.select([changed], cache, "sources")
    end

    assert {[^q], [], []} = AuditCache.select([q], cache, "new sources")
  end

  test "persisted image filenames and UUIDs do not invalidate an unchanged document" do
    q = question("q1", "document")
    cache = AuditCache.record([q], [q], "sources")
    saved = Map.merge(q, %{"id" => "uuid", "images" => [%{"storage_key" => "snapshot.png"}]})
    assert {[], [], [^saved]} = AuditCache.select([saved], cache, "sources")
  end

  defp question(id, basis),
    do: %{"plan_id" => id, "prompt" => id, "text" => "Document", "answer_basis" => basis}
end
