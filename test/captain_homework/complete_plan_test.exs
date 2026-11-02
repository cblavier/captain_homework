defmodule CaptainHomework.CompletePlanTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.Plan
  @pages [%{id: "course", kind: "lesson"}, %{id: "resource", kind: "resource"}]

  defp question(n) do
    %{
      "id" => "q#{n}",
      "plan_id" => "q#{n}",
      "type" => "long",
      "objective" => "Notion #{n}",
      "skill" => "recall",
      "response_effort" => "direct",
      "answer_basis" => "knowledge",
      "expected_elements" => ["Fait #{n}"],
      "source_page_ids" => ["course"],
      "support_id" => "",
      "prompt" => "Question #{n}",
      "text" => "",
      "answer" => "Réponse #{n}",
      "rubric" => "Un élément juste.",
      "points" => 1,
      "options" => [],
      "slots" => [],
      "diagram" => nil,
      "image_ids" => []
    }
  end

  test "v2 questions cannot display an image outside the transmitted candidate set" do
    q = Map.put(question(1), "image_ids", ["hidden-resource"])
    plan = %{"questions" => [q], "supports" => []}

    assert {:error, message} =
             Plan.validate_complete(plan, 1, ["long"], @pages, [%{id: "visible-resource"}])

    assert message =~ "non transmise"
    assert :ok = Plan.validate_complete(plan, 1, ["long"], @pages, [%{id: "hidden-resource"}])
  end

  test "complete validation keeps diagram bounds and slot matching checks" do
    node = %{"shape" => "rect", "label" => "1", "x" => 0, "y" => 0, "width" => 50, "height" => 50}

    q =
      question(1)
      |> Map.merge(%{"type" => "diagram", "slots" => ["1"], "diagram" => %{"nodes" => [node]}})

    plan = %{"questions" => [q], "supports" => []}
    assert :ok = Plan.validate_complete(plan, 1, ["diagram"], @pages, [])

    invalid =
      put_in(plan, ["questions"], [put_in(q, ["diagram", "nodes"], [Map.put(node, "y", 290)])])

    assert {:error, _} = Plan.validate_complete(invalid, 1, ["diagram"], @pages, [])
    mismatched = put_in(plan, ["questions"], [Map.put(q, "slots", ["2"])])
    assert {:error, _} = Plan.validate_complete(mismatched, 1, ["diagram"], @pages, [])
  end

  test "thirty complete questions can satisfy both feasible target sets" do
    questions =
      for n <- 1..30 do
        effort =
          cond do
            n <= 12 -> "direct"
            n <= 24 -> "short"
            true -> "developed"
          end

        basis = if n <= 15, do: "knowledge", else: "document"
        question(n) |> Map.put("response_effort", effort) |> Map.put("answer_basis", basis)
      end

    assert :ok =
             Plan.validate_complete(
               %{"questions" => questions, "supports" => []},
               30,
               ["long"],
               @pages,
               []
             )
  end
end
