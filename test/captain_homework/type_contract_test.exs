defmodule CaptainHomework.Exams.TypeContractTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{BuildError, ExerciseDraft, ExerciseSpec, TypeContract}

  defp definition(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "definition",
        "revision" => 3,
        "name" => "Définition",
        "subjects" => ["svt"],
        "modes" => ["classic", "flashcard"],
        "instruction_kind" => "fixed",
        "instruction" => "Définis le terme suivant.",
        "content_kind" => "text",
        "content_presence" => "required",
        "response_kind" => "short_text"
      },
      attrs
    )
  end

  defp context(definitions \\ [definition()]) do
    TypeContract.context(definitions, "classic", "svt")
    |> Map.merge(%{
      types: ["definition"],
      sources: [%{id: "source", kind: "lesson"}],
      images: [],
      supports: []
    })
  end

  defp question(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "q1",
        "definition_id" => "definition",
        "type" => "definition",
        "task" => "Définir la membrane",
        "prompt" => "Définis le terme suivant.",
        "text" => "Membrane",
        "answer" => "Enveloppe de la cellule",
        "rubric" => "Enveloppe qui délimite la cellule",
        "points" => 2,
        "objective" => "Membrane",
        "skill" => "recall",
        "response_effort" => "direct",
        "answer_basis" => "knowledge",
        "expected_elements" => ["enveloppe"],
        "source_page_ids" => ["source"],
        "options" => [],
        "slots" => [],
        "diagram" => nil
      },
      attrs
    )
  end

  test "fixed instruction is assembled before drafting and cannot be changed" do
    assert {:ok, spec} =
             ExerciseSpec.new(question(%{"prompt" => "Réécriture non autorisée"}), context())

    assert spec.initial_prompt == "Définis le terme suivant."
    assert spec.question["type_contract"]["revision"] == 3
    payload = %{"spec_id" => spec.id, "spec_hash" => spec.hash, "prompt" => spec.initial_prompt}
    assert {:ok, _} = ExerciseDraft.new(spec, payload)

    assert {:error, %BuildError{kind: :invalid_draft}} =
             ExerciseDraft.new(spec, Map.put(payload, "prompt", "Donne aussi deux dates."))

    assert {:error, _} =
             TypeContract.validate(question(%{"prompt" => "Donne deux dates."}), context())

    assert {:ok, _} = ExerciseSpec.from_map(ExerciseSpec.to_map(spec), context())
    assert {:error, _} = ExerciseSpec.validate(spec, context([definition(%{"revision" => 4})]))
    assert {:error, _} = ExerciseSpec.validate(spec, context([]))
  end

  test "AI projection excludes inactive instructions from nested repair snapshots only" do
    dynamic =
      definition(%{"instruction_kind" => "dynamic", "instruction" => "HIDDEN_STATIC_SENTINEL"})

    stored = %{
      "type_context" => %{"definitions" => [dynamic, definition()]},
      "exercise_specs" => %{"q1" => %{"question" => %{"type_contract" => dynamic}}},
      "prompt" => "Consigne dynamique effectivement rédigée"
    }

    projected = CaptainHomework.QuestionDefinitions.ai_context(stored)
    refute Jason.encode!(projected) =~ "HIDDEN_STATIC_SENTINEL"
    assert hd(stored["type_context"]["definitions"])["instruction"] == "HIDDEN_STATIC_SENTINEL"

    assert Enum.at(projected["type_context"]["definitions"], 1)["instruction"] ==
             definition()["instruction"]

    assert projected["prompt"] == stored["prompt"]

    type = %CaptainHomework.Study.QuestionDefinition{
      name: "Dynamique",
      instruction_kind: "dynamic",
      instruction: "HIDDEN_STATIC_SENTINEL"
    }

    refute CaptainHomework.QuestionDefinitions.instructions([type]) =~ "HIDDEN_STATIC_SENTINEL"
  end

  test "examples are indicative and limited to active editor fields and current mode" do
    type =
      definition(%{
        "example" => %{
          "prompt" => "HIDDEN_PROMPT",
          "text" => "Cellule",
          "document" => "HIDDEN_DOCUMENT"
        },
        "help_classic" => "Aide classique",
        "help_flashcard" => "HIDDEN_HELP"
      })

    projected =
      CaptainHomework.QuestionDefinitions.ai_context(%{
        "mode" => "classic",
        "definitions" => [type]
      })

    [visible] = projected["definitions"]
    assert visible["indicative_example"]["content"] == %{"text" => "Cellule"}
    assert visible["indicative_example"]["usage"] =~ "contrat"
    refute Map.has_key?(visible, "help_classic")
    refute Map.has_key?(visible, "help_flashcard")
    refute Jason.encode!(projected) =~ "HIDDEN"
    refute Map.has_key?(visible, "example")
    assert type["example"]["prompt"] == "HIDDEN_PROMPT"

    dynamic = Map.merge(type, %{"instruction_kind" => "dynamic", "content_presence" => "none"})

    assert CaptainHomework.QuestionDefinitions.ai_context(dynamic)["indicative_example"][
             "content"
           ] ==
             %{"prompt" => "HIDDEN_PROMPT"}

    document = Map.put(type, "content_kind", "document")

    assert CaptainHomework.QuestionDefinitions.ai_context(document)["indicative_example"][
             "content"
           ] ==
             %{"document" => "HIDDEN_DOCUMENT"}
  end

  defp fields do
    text = %{"type" => "string"}
    array = %{"type" => "array", "items" => text}
    nullable = %{"anyOf" => [%{"type" => "object", "properties" => %{}}, %{"type" => "null"}]}

    %{
      "type" => text,
      "definition_id" => text,
      "task" => text,
      "prompt" => text,
      "text" => text,
      "options" => array,
      "slots" => array,
      "image_ids" => array,
      "support_id" => text,
      "diagram" => nullable,
      "audio_script" => nullable,
      "answer" => text
    }
  end

  test "schema and assembly have complementary ownership for fixed and dynamic types" do
    dynamic =
      definition(%{
        "id" => "dynamic",
        "instruction_kind" => "dynamic",
        "content_presence" => "optional"
      })

    ctx = context([definition(), dynamic])
    assert %{"anyOf" => [fixed, free]} = TypeContract.schema(fields(), ctx, %{}, :spec)
    assert fixed["properties"]["text"]["pattern"] == "\\S"

    for key <- ~w(prompt task options slots image_ids audio_script diagram support_id),
        do: refute(Map.has_key?(fixed["properties"], key))

    assert free["properties"]["task"]["pattern"] == "\\S"
    refute free["properties"]["text"]["pattern"]

    raw = %{"definition_id" => "definition", "type" => "definition", "text" => "Membrane"}
    assert {:ok, built} = TypeContract.assemble(raw, ctx, :final)
    assert built["prompt"] == definition()["instruction"]
    assert built["options"] == []
    assert built["audio_script"] == nil
    assert {:ok, _} = TypeContract.validate(built, ctx)
    assert {:error, _} = TypeContract.assemble(Map.put(raw, "audio_script", %{}), ctx, :final)

    assert {:error, _} =
             TypeContract.assemble(Map.put(raw, "prompt", "Autre consigne"), ctx, :final)
  end

  test "content and response formats constrain schema branches without impossible media choices" do
    for {response, kind, field} <- [
          {"single_choice", "text", "options"},
          {"cloze", "text", "slots"},
          {"ordering", "text", "options"},
          {"legends", "image", "diagram"},
          {"short_text", "audio", "audio_script"}
        ] do
      ctx = context([definition(%{"response_kind" => response, "content_kind" => kind})])
      schema = TypeContract.schema(fields(), ctx)
      assert schema["properties"][field]
      assert TypeContract.schema_possible?(schema)
      if field in ~w(options slots), do: assert(schema["properties"][field]["minItems"] >= 1)
      if response == "ordering", do: assert(schema["properties"][field]["minItems"] == 2)
      if field in ~w(diagram audio_script), do: refute(schema["properties"][field]["anyOf"])
    end

    unavailable =
      fields()
      |> Map.put("image_ids", %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "maxItems" => 0
      })
      |> Map.put("support_id", %{"type" => "string", "enum" => [""]})

    document =
      context([definition(%{"response_kind" => "long_text", "content_kind" => "document"})])

    schema = TypeContract.schema(unavailable, document)
    assert schema["properties"]["text"]["pattern"] == "\\S"
    assert TypeContract.schema_possible?(schema)
    image = context([definition(%{"content_kind" => "image"})])
    refute TypeContract.schema_possible?(TypeContract.schema(unavailable, image))
  end

  test "required shared supports exclude blank enum values while other branches allow no support" do
    document =
      context([definition(%{"response_kind" => "long_text", "content_kind" => "document"})])

    properties =
      fields()
      |> Map.put("image_ids", %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "maxItems" => 0
      })
      |> Map.put("support_id", %{"type" => "string", "enum" => ["", " ", "s1", "s2", "s3"]})

    for phase <- [:spec, :final] do
      assert %{"anyOf" => [text_branch, support_branch]} =
               TypeContract.schema(properties, document, %{}, phase)

      support = support_branch["properties"]["support_id"]
      assert support["enum"] == ["s1", "s2", "s3"]
      assert Enum.all?(support["enum"], &Regex.match?(Regex.compile!(support["pattern"]), &1))
      assert "" in text_branch["properties"]["support_id"]["enum"]
      refute text_branch["properties"]["support_id"]["pattern"]
    end
  end

  test "same format does not identify two different catalogue types" do
    context =
      context([definition(), definition(%{"id" => "vocabulary", "instruction" => "Traduis."})])

    assert {:error, _} = TypeContract.bind(Map.delete(question(), "definition_id"), context)
    assert {:ok, bound} = TypeContract.bind(question(), context)
    assert bound["type_contract"]["id"] == "definition"
    assert {:error, _} = TypeContract.bind(question(%{"definition_id" => "unknown"}), context)
    assert {:error, _} = TypeContract.bind(question(%{"type" => "mcq"}), context)
  end

  test "required optional and forbidden content are enforced" do
    assert {:error, _} = TypeContract.validate(question(%{"text" => "  "}), context())
    optional = context([definition(%{"content_presence" => "optional"})])
    assert {:ok, _} = TypeContract.validate(question(%{"text" => ""}), optional)
    assert {:ok, _} = TypeContract.validate(question(), optional)

    assert {:error, _} =
             TypeContract.validate(question(%{"text" => "", "image_ids" => ["image"]}), optional)

    forbidden = context([definition(%{"content_presence" => "none"})])
    assert {:ok, _} = TypeContract.validate(question(%{"text" => ""}), forbidden)

    for attrs <- [
          %{"text" => "term"},
          %{"text" => "", "support_text" => "document"},
          %{"text" => "", "image_ids" => ["image"]}
        ] do
      assert {:error, _} = TypeContract.validate(question(attrs), forbidden)
    end
  end

  test "content is checked after attaching shared supports" do
    ctx = %{
      context([definition(%{"content_kind" => "document"})])
      | supports: [
          %{"id" => "s1", "text" => "Document lisible", "title" => "Document", "image_ids" => []}
        ]
    }

    assert {:ok, _} =
             ExerciseSpec.new(
               question(%{"text" => "", "support_id" => "s1", "answer_basis" => "document"}),
               ctx
             )

    assert {:error, _} =
             ExerciseSpec.new(
               question(%{"text" => "", "support_id" => "s1", "answer_basis" => "document"}),
               %{ctx | supports: []}
             )
  end

  test "mode subject and configured language substitutions are binding" do
    assert {:error, _} = TypeContract.bind(question(), %{context() | mode: "other"})
    assert {:error, _} = TypeContract.bind(question(), %{context() | subject: "anglais"})

    ctx =
      TypeContract.context(
        [definition(%{"subjects" => ["anglais"], "instruction" => "Traduis en {langue}."})],
        "flashcard",
        "anglais"
      )

    assert {:ok, bound} =
             TypeContract.validate(question(%{"prompt" => "Traduis en anglais."}), ctx)

    assert TypeContract.fixed_prompt(bound) == "Traduis en anglais."
  end

  test "dynamic instructions remain free and unexpected response fields are rejected" do
    assert {:ok, _} =
             TypeContract.validate(
               question(%{"prompt" => "Une consigne spécifique"}),
               context([definition(%{"instruction_kind" => "dynamic"})])
             )

    qcm = question(%{"type" => "mcq", "options" => ["A", "B"], "answer" => "A"})
    assert CaptainHomework.AI.question_errors(qcm) == []
    assert CaptainHomework.AI.question_errors(Map.put(qcm, "slots", ["1"])) != []
    assert CaptainHomework.AI.question_errors(Map.put(qcm, "diagram", %{})) != []
  end
end
