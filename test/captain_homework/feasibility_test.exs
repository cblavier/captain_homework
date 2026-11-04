defmodule CaptainHomework.Exams.FeasibilityTest do
  use ExUnit.Case, async: true

  alias CaptainHomework.Exams.{BuildError, Feasibility, Instructions}

  defp entry(source_id, attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "knowledge",
        "title" => "Le périmètre",
        "content" => "Le périmètre d'un polygone est la somme des longueurs de ses côtés.",
        "source_page_ids" => [source_id],
        "visual_page_ids" => [],
        "usable" => true
      },
      attrs
    )
  end

  defp decision(attrs \\ %{}) do
    Map.merge(
      %{
        "status" => "compatible",
        "reason" => "",
        "included_ids" => [0],
        "evidence_ids" => [0],
        "use_examples" => true
      },
      attrs
    )
  end

  defp course, do: %{id: "course", kind: "lesson"}

  test "accepts a grounded selection and preserves its order and example policy" do
    pages = [course(), %{id: "figure", kind: "illustration", resource_id: "resource"}]

    figure =
      entry("figure", %{
        "kind" => "visual",
        "content" => "Un quadrilatère avec les longueurs de ses côtés.",
        "visual_page_ids" => ["figure"]
      })

    knowledge = entry("course")
    entries = [knowledge, figure]
    result = decision(%{"included_ids" => [1, 0], "use_examples" => false})

    assert {:ok, [^figure, ^knowledge], false} = Feasibility.decode(result, entries, pages)
  end

  test "a document exercise can establish feasibility without a separate course entry" do
    page = %{id: "activity", kind: "resource"}
    exercise = entry(page.id, %{"kind" => "exercise"})

    assert {:ok, [^exercise], true} =
             Feasibility.decode(decision(), [exercise], [page])
  end

  test "contradictory constraints stop before question generation with an explicit reason" do
    result =
      decision(%{
        "status" => "incompatible",
        "reason" =>
          "Le seul cours disponible porte sur les périmètres, que tu demandes d'exclure.",
        "included_ids" => []
      })

    assert {:error, %BuildError{} = error} =
             Feasibility.decode(result, [entry("course")], [course()])

    assert error.kind == :incompatible_instructions
    assert error.stage == :instructions
    refute error.retryable?
    assert error.message =~ "que tu demandes d'exclure"
    assert error.details["evidence_ids"] == [0]
  end

  test "genuine ambiguity requests clarification without selecting a partial scope" do
    result =
      decision(%{
        "status" => "needs_clarification",
        "reason" => "Précise lequel des deux chapitres doit être exclu.",
        "included_ids" => []
      })

    assert {:error, %BuildError{} = error} =
             Feasibility.decode(result, [entry("course")], [course()])

    assert error.kind == :unclear_instructions
    assert error.message =~ "Précise lequel"
    refute error.retryable?
  end

  test "an empty catalogue can yield an explained refusal with no fabricated evidence" do
    result =
      decision(%{
        "status" => "incompatible",
        "reason" => "Aucun cours n'est disponible pour enseigner cette notion.",
        "included_ids" => [],
        "evidence_ids" => []
      })

    assert {:error, %BuildError{kind: :incompatible_instructions}} =
             Feasibility.decode(result, [], [])
  end

  test "rejects old, malformed, and unknown decisions instead of silently accepting them" do
    malformed = [
      nil,
      "compatible",
      %{"included_ids" => [0], "use_examples" => true},
      decision(%{"status" => "probably"}),
      decision(%{"reason" => nil}),
      decision(%{"use_examples" => "false"}),
      decision(%{"extra" => true})
    ]

    for result <- malformed do
      assert {:error, %BuildError{kind: :invalid_feasibility, retryable?: false}} =
               Feasibility.decode(result, [entry("course")], [course()])
    end
  end

  test "rejects unknown, duplicate, and incorrectly typed selection or evidence indices" do
    for key <- ["included_ids", "evidence_ids"],
        ids <- [[1], [-1], [0, 0], ["0"], [0.0], nil] do
      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(decision(%{key => ids}), [entry("course")], [course()])
    end
  end

  test "a compatible decision must include actual teaching content and evidence for it" do
    for attrs <- [
          %{"included_ids" => [], "evidence_ids" => []},
          %{"evidence_ids" => []},
          %{"included_ids" => [], "evidence_ids" => [0]}
        ] do
      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(decision(attrs), [entry("course")], [course()])
    end

    unusable = entry("course", %{"usable" => false})

    assert {:error, %BuildError{kind: :invalid_feasibility}} =
             Feasibility.decode(decision(), [unusable], [course()])
  end

  test "unselected knowledge cannot justify a selection containing only a visual support" do
    visual = entry("course", %{"kind" => "visual"})
    entries = [entry("course"), visual]

    for attrs <- [
          %{"included_ids" => [1], "evidence_ids" => [0]},
          %{"included_ids" => [1], "evidence_ids" => [1]},
          %{"included_ids" => [0, 1], "evidence_ids" => [1]}
        ] do
      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(decision(attrs), entries, [course()])
    end
  end

  test "a refusal cannot contain an accepted selection or an empty explanation" do
    for status <- ["incompatible", "needs_clarification"],
        attrs <- [
          %{"included_ids" => [0], "reason" => "Le cours manque."},
          %{"included_ids" => [], "reason" => " \n "}
        ] do
      result = decision(Map.put(attrs, "status", status))

      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(result, [entry("course")], [course()])
    end
  end

  test "examples can guide form but cannot become the source of knowledge" do
    example_page = %{id: "example", kind: "example"}

    for use_examples? <- [true, false] do
      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(
                 decision(%{"use_examples" => use_examples?}),
                 [entry("example")],
                 [example_page]
               )
    end

    mixed_entry = entry("course", %{"source_page_ids" => ["course", "example"]})

    assert {:error, %BuildError{kind: :invalid_feasibility}} =
             Feasibility.decode(decision(), [mixed_entry], [course(), example_page])

    assert {:ok, [_], true} =
             Feasibility.decode(decision(), [entry("course")], [course(), example_page])
  end

  test "selected content must reference available sources" do
    for source_ids <- [[], ["missing"], ["course", "missing"], nil] do
      unsupported = entry("course", %{"source_page_ids" => source_ids})

      assert {:error, %BuildError{kind: :invalid_feasibility}} =
               Feasibility.decode(decision(), [unsupported], [course()])
    end
  end

  test "prompt distinguishes derivable applications, external facts, visuals and examples" do
    instructions =
      Instructions.compose(
        "Des additions pour calculer des périmètres.",
        "Ancien diagnostic de réparation à ne pas utiliser."
      )

    prompt = Feasibility.prompt([entry("course")], [course()], instructions)

    assert prompt =~ "Des additions pour calculer des périmètres."
    assert prompt =~ "une somme de longueurs"
    assert prompt =~ "Une image ne remplace pas un cours absent"
    assert prompt =~ "uniquement la forme"
    assert prompt =~ "sans doublon"
    assert prompt =~ ~s("selection_id":0)
    refute prompt =~ "Ancien diagnostic"
  end

  test "the schema requires a feasibility decision alongside the existing selection fields" do
    schema = Feasibility.schema()

    assert schema["additionalProperties"] == false

    assert MapSet.new(schema["required"]) ==
             MapSet.new(~w(status reason included_ids evidence_ids use_examples))

    assert schema["properties"]["status"]["enum"] == [
             "compatible",
             "incompatible",
             "needs_clarification"
           ]
  end
end
