defmodule CaptainHomework.ExamPlanTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{Plan, SupportGroups}

  defp slot(id, objective, skill) do
    %{
      "id" => id,
      "type" => "reading",
      "objective" => objective,
      "skill" => skill,
      "expected_elements" => [objective],
      "source_page_ids" => ["page"],
      "support_id" => "doc"
    }
  end

  defp plan do
    %{
      "questions" => [
        slot("q1", "Identifier les auteurs", "identify_source"),
        slot("q2", "Vitesse des migrations", "interpret")
      ],
      "supports" => [
        %{
          "id" => "doc",
          "title" => "Les migrations",
          "text" => "Texte commun et sa source.",
          "image_ids" => []
        }
      ]
    }
  end

  test "a shared support is valid only with distinct objectives and real sources" do
    assert :ok = Plan.validate(plan(), 2, ["reading"], [%{id: "page"}], [])

    duplicate =
      put_in(plan(), ["questions"], [
        slot("q1", "La migration", "recall"),
        slot("q2", "LA MIGRATION", "recall")
      ])

    assert {:error, _} = Plan.validate(duplicate, 2, ["reading"], [%{id: "page"}], [])
    assert {:error, _} = Plan.validate(plan(), 2, ["reading"], [%{id: "different"}], [])
    assert {:error, _} = Plan.validate(plan(), 2, ["mcq"], [%{id: "page"}], [])
  end

  test "a term shared with another document does not prove that the answer is revealed" do
    q1 =
      slot("q1", "Origine", "locate")
      |> Map.merge(%{"expected_elements" => ["Afrique"], "support_id" => ""})

    q2 = slot("q2", "Vitesse", "interpret")

    p = %{
      plan()
      | "questions" => [q1, q2],
        "supports" => [
          %{
            "id" => "doc",
            "title" => "Migrations",
            "text" => "Cette carte représente les migrations en Afrique.",
            "image_ids" => []
          }
        ]
    }

    assert :ok = Plan.validate(p, 2, ["reading"], [%{id: "page"}], [])

    # Extracting the answer from the associated (possibly shared) document is valid.
    associated = put_in(p, ["questions"], [Map.put(q1, "support_id", "doc"), q2])
    assert :ok = Plan.validate(associated, 2, ["reading"], [%{id: "page"}], [])

    assert {:error, _} =
             Plan.validate(%{"questions" => [nil], "supports" => []}, 1, ["reading"], [], [])
  end

  test "questions sharing a document remain together even after repairs" do
    [a, b] = plan()["questions"]
    separate = slot("q3", "Autre notion", "recall") |> Map.put("support_id", "")
    p = %{plan() | "questions" => [a, separate, b]}
    ordered = Plan.order([%{"plan_id" => "q2"}, %{"plan_id" => "q3"}, %{"plan_id" => "q1"}], p)
    assert Enum.map(ordered, & &1["plan_id"]) == ["q1", "q2", "q3"]
  end

  test "drafts must match their slot and use the canonical shared support" do
    q = %{
      "plan_id" => "q1",
      "type" => "reading",
      "text" => "A variant missing the source",
      "image_ids" => []
    }

    assert {:ok, bound} = Plan.attach(q, plan()["questions"], plan()["supports"])
    assert bound["text"] == "Texte commun et sa source."

    assert :error =
             Plan.attach(
               Map.put(q, "plan_id", "invented"),
               plan()["questions"],
               plan()["supports"]
             )

    assert :error =
             Plan.attach(Map.put(q, "type", "long"), plan()["questions"], plan()["supports"])
  end

  test "planned response effort survives drafting and invalid categories are rejected" do
    questions =
      plan()["questions"]
      |> Enum.zip(["short", "direct"])
      |> Enum.map(fn {q, effort} -> Map.put(q, "response_effort", effort) end)

    p = Map.put(plan(), "questions", questions)
    assert :ok = Plan.validate(p, 2, ["reading"], [%{id: "page"}], [])

    assert {:ok, bound} =
             Plan.attach(
               %{"plan_id" => "q1", "type" => "reading", "response_effort" => "developed"},
               questions,
               p["supports"]
             )

    assert bound["response_effort"] == "short"

    invalid =
      Map.put(p, "questions", Enum.map(questions, &Map.put(&1, "response_effort", "invalid")))

    assert {:error, _} = Plan.validate(invalid, 2, ["reading"], [%{id: "page"}], [])
  end

  test "legacy passages differing only by a source citation share the complete passage" do
    text = String.duplicate("Les migrations se font lentement. ", 12)

    first = %{
      "id" => "q1",
      "type" => "reading",
      "text" => text <> "Source : ouvrage, 2016.",
      "image_ids" => []
    }

    second = %{"id" => "q2", "type" => "reading", "text" => text, "image_ids" => []}

    assert [%{shared?: true, support: ^first, questions: [{^first, 1}, {^second, 2}]}] =
             SupportGroups.build([first, second])

    refute hd(SupportGroups.build([first, Map.put(second, "text", "Un autre document")])).shared?
    assert length(SupportGroups.build([first, Map.put(second, "type", "cloze")])) == 2
  end

  test "identical maps group without conflating distinct images or empty supports" do
    q = %{"id" => "q1", "type" => "long", "text" => "", "image_ids" => ["map"]}
    assert [%{shared?: true}] = SupportGroups.build([q, Map.put(q, "id", "q2")])
    assert length(SupportGroups.build([q, Map.put(q, "image_ids", ["other-map"])])) == 2
    empty = Map.put(q, "image_ids", [])
    assert length(SupportGroups.build([empty, Map.put(empty, "id", "q2")])) == 2
  end
end
