defmodule CaptainHomework.RepairContextTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.AI.RepairContext

  test "repair includes needed evidence and visible context, not unused images and answers" do
    accepted = %{
      "id" => "q1",
      "plan_id" => "q1",
      "prompt" => "Question acceptée",
      "answer" => "secret answer",
      "rubric" => "secret rubric",
      "text" => "Texte partagé",
      "support_text" => "Texte partagé",
      "support_id" => "shared",
      "image_ids" => ["visible"],
      "image_regions" => [
        %{"image_id" => "visible", "x" => 0, "y" => 500, "width" => 1000, "height" => 500}
      ]
    }

    rejected = %{
      "id" => "q2",
      "source_page_ids" => ["needed"],
      "support_id" => "",
      "image_ids" => []
    }

    entries = [
      entry("exercise", ["needed", "dependency"], ["diagram"]),
      entry("knowledge", ["dependency"], []),
      entry("exercise", ["unrelated"], ["unused"])
    ]

    plan = %{
      "questions" => [accepted, rejected],
      "supports" => [%{"id" => "shared", "text" => "Texte partagé", "image_ids" => ["visible"]}],
      "context" => Jason.encode!(%{"catalogue" => entries, "source_kinds" => %{}})
    }

    result =
      RepairContext.build(plan, [rejected], Enum.map(~w(visible diagram unused), &%{id: &1}))

    assert Enum.map(result.images, & &1.id) == ~w(visible diagram)
    assert Jason.decode!(result.content)["catalogue"] == Enum.take(entries, 2)
    assert hd(result.retained)["prompt"] == accepted["prompt"]
    assert hd(result.retained)["text"] == ""
    assert hd(result.retained)["image_regions"] == accepted["image_regions"]
    refute Map.has_key?(hd(result.retained), "answer")
    refute Map.has_key?(hd(result.retained), "rubric")
    assert result.supports == plan["supports"]
  end

  test "an autonomous question keeps all its visible text" do
    q = %{"text" => "Une légende indispensable", "support_id" => ""}
    assert RepairContext.compact_support(q) == q
  end

  test "compacting a shared document never removes the question's own task" do
    q = %{
      "text" => "Qui sont les auteurs ?",
      "support_text" => "Document et sa source.",
      "support_id" => "doc"
    }

    compact = RepairContext.compact_support(q)
    assert compact["text"] == q["text"]
    refute Map.has_key?(compact, "support_text")
    assert RepairContext.visible_question(q) == compact
    assert RepairContext.compact_support(Map.delete(q, "support_text")) == compact

    standalone = Map.put(q, "support_id", "")
    assert RepairContext.compact_support(standalone) == standalone
  end

  test "unknown source references can be repaired using the available catalogue" do
    content =
      Jason.encode!(%{
        "catalogue" => [entry("exercise", ["valid"], ["page"])],
        "source_kinds" => %{"valid" => "resource"}
      })

    assert RepairContext.filter_catalogue(content, ["unknown"], fallback: true) == content
  end

  test "a knowledge question with a wrong resource citation receives the course evidence needed to fix it" do
    course = entry("knowledge", ["course"], [])
    resource = entry("exercise", ["resource"], [])
    other = entry("exercise", ["unrelated"], ["unused"])

    question = %{
      "id" => "q1",
      "answer_basis" => "knowledge",
      "source_page_ids" => ["resource"],
      "image_ids" => [],
      "support_id" => ""
    }

    context = %{
      "catalogue" => [course, resource, other],
      "source_kinds" => %{
        "course" => "lesson",
        "resource" => "resource",
        "unrelated" => "resource"
      }
    }

    result =
      RepairContext.build(
        %{"questions" => [question], "supports" => [], "context" => Jason.encode!(context)},
        [question],
        [%{id: "unused"}]
      )

    assert course in Jason.decode!(result.content)["catalogue"]
    refute other in Jason.decode!(result.content)["catalogue"]
    assert result.images == []
  end

  defp entry(kind, sources, images),
    do: %{"kind" => kind, "source_page_ids" => sources, "visual_page_ids" => images}
end
