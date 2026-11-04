defmodule CaptainHomework.ExerciseContractTest do
  use ExUnit.Case, async: true

  alias CaptainHomework.Exams.{BuildError, ExerciseDraft, ExerciseSpec, ValidatedExercise}

  defp slot do
    %{
      "id" => "q1",
      "task" => "Calculer une aire de triangle en justifiant le calcul.",
      "type" => "long",
      "objective" => "Aire du triangle",
      "skill" => "justify",
      "response_effort" => "short",
      "answer_basis" => "knowledge",
      "expected_elements" => ["20 cm² avec calcul justifié"],
      "source_page_ids" => ["course"],
      "image_ids" => ["triangle"],
      "answer" => "20 cm²",
      "rubric" => "Base × hauteur ÷ 2 et unité correcte.",
      "points" => 2
    }
  end

  defp context do
    %{
      sources: [%{id: "course", kind: "lesson", text: "L’aire vaut base × hauteur ÷ 2."}],
      images: [
        %{
          id: "triangle",
          storage_key: "triangle.png",
          content_type: "image/png",
          content_hash: "bytes-v1"
        },
        %{id: "shared", storage_key: "shared.png", content_type: "image/png"}
      ],
      supports: [],
      types: ["long"]
    }
  end

  defp draft(spec, prompt \\ "Calcule l’aire du triangle et justifie ton calcul.") do
    ExerciseDraft.new(spec, %{"spec_id" => spec.id, "spec_hash" => spec.hash, "prompt" => prompt})
  end

  defp roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()

  test "a contract needs a task but no drafted instruction and preserves every fixed field" do
    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert is_nil(spec.initial_prompt)
    assert spec.task == slot()["task"]
    assert {:ok, draft} = draft(spec)
    assert {:ok, exercise} = ExerciseDraft.build(spec, draft, context())
    question = ValidatedExercise.to_question(exercise)

    for {key, value} <- spec.question, do: assert(question[key] == value)
    assert question["prompt"] == draft.prompt
    assert question["exercise_spec_hash"] == spec.hash
    assert question["exercise_spec_id"] == "q1"
    assert question["exercise_spec_version"] == 1
    assert question["structural_validation"] == "valid"
    assert question["pedagogical_audit"] == "pending"
    assert exercise.structural_validation == :valid
    assert exercise.pedagogical_audit == :pending
  end

  test "legacy prompt provides a migration task without granting it pedagogical approval" do
    legacy = slot() |> Map.delete("task") |> Map.put("prompt", "Calcule l’aire.")
    assert {:ok, spec} = ExerciseSpec.new(legacy, context())
    assert spec.initial_prompt == "Calcule l’aire."
    assert spec.task == spec.initial_prompt

    assert {:error, %BuildError{kind: :invalid_contract}} =
             ExerciseSpec.new(Map.delete(slot(), "task"), context())
  end

  test "context accepts real Ecto page structs and string keyed source descriptors" do
    source = %CaptainHomework.Study.Page{
      id: "course",
      kind: "lesson",
      text: "Aire du triangle",
      status: "ready"
    }

    image = %CaptainHomework.Study.Page{
      id: "triangle",
      kind: "illustration",
      storage_key: "figure.png",
      content_type: "image/png",
      status: "ready"
    }

    context = %{context() | sources: [source], images: [image]}
    assert {:ok, spec} = ExerciseSpec.new(slot(), context)
    assert :ok = ExerciseSpec.validate(spec, context)

    string_context =
      Map.put(context(), :sources, [
        %{"id" => "course", "kind" => "lesson", "text" => "Aire du triangle"}
      ])

    assert {:ok, _} = ExerciseSpec.new(slot(), string_context)
  end

  test "source availability and response format constrain the declared effort and answer basis" do
    source_without_course = %{
      context()
      | sources: [%{id: "course", kind: "resource", text: "Document"}]
    }

    assert {:error, %BuildError{kind: :incompatible_constraints}} =
             ExerciseSpec.new(slot(), source_without_course)

    question = Map.merge(slot(), %{"type" => "mcq", "options" => ["20 cm²", "40 cm²"]})

    assert {:error, %BuildError{kind: :incompatible_constraints}} =
             ExerciseSpec.new(question, %{context() | types: ["mcq"]})
  end

  test "knowledge needs its own cited course even when unrelated courses are available" do
    sources = context().sources ++ [%{id: "resource", kind: "resource", text: "Un document"}]
    question = Map.put(slot(), "source_page_ids", ["resource"])

    assert {:error, %BuildError{kind: :incompatible_constraints}} =
             ExerciseSpec.new(question, %{context() | sources: sources})

    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert spec.question["answer_basis"] == "knowledge"
    assert spec.question["image_ids"] == ["triangle"]

    support = %{"id" => "s1", "title" => "Document", "text" => "Référence", "image_ids" => []}

    assert {:error, %BuildError{kind: :incompatible_constraints}} =
             ExerciseSpec.new(Map.put(slot(), "support_id", "s1"), %{
               context()
               | supports: [support]
             })
  end

  test "draft cannot mutate answer, sources, images, metadata or any other unknown field" do
    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert {:ok, draft} = draft(spec)
    payload = ExerciseDraft.to_map(draft)

    for {field, changed} <- [
          {"answer", "40 cm²"},
          {"source_page_ids", ["other"]},
          {"image_ids", []},
          {"metadata", %{}},
          {"task", "Inventer une réponse"},
          {"extra", nil}
        ] do
      assert {:error, %BuildError{kind: :invalid_draft, retryable?: false}} =
               ExerciseDraft.new(spec, Map.put(payload, field, changed))
    end

    for field <- ~w(spec_id spec_hash) do
      assert {:error, %BuildError{kind: :contract_mismatch}} =
               ExerciseDraft.new(spec, Map.put(payload, field, "other"))
    end
  end

  test "mutating a typed contract or draft cannot bypass the construction boundary" do
    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert {:ok, draft} = draft(spec)

    for {field, changed} <- [{"answer", "40 cm²"}, {"source_page_ids", []}, {"image_ids", []}] do
      changed_spec = %{spec | question: Map.put(spec.question, field, changed)}

      assert {:error, %BuildError{kind: :contract_mismatch}} =
               ExerciseDraft.build(changed_spec, draft, context())
    end

    assert {:error, %BuildError{kind: :contract_mismatch}} =
             ExerciseDraft.build(spec, %{draft | spec_hash: "stale"}, context())
  end

  test "dependencies are checked before building and source or image revisions invalidate the contract" do
    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert {:ok, draft} = draft(spec)

    for key <- [:sources, :images] do
      assert {:error, %BuildError{kind: :missing_dependency}} =
               ExerciseDraft.build(spec, draft, Map.put(context(), key, []))
    end

    changed_sources = put_in(context(), [:sources, Access.at(0), :text], "Contenu modifié.")
    changed_image = put_in(context(), [:images, Access.at(0), :content_hash], "bytes-v2")

    for changed <- [changed_sources, changed_image] do
      assert {:error, %BuildError{kind: :stale_dependency}} =
               ExerciseDraft.build(spec, draft, changed)
    end

    duplicate = Map.update!(context(), :sources, &(&1 ++ &1))
    assert {:error, %BuildError{kind: :missing_dependency}} = ExerciseSpec.new(slot(), duplicate)
  end

  test "own and shared documents are combined without losing the question's image or crop" do
    crop = %{"image_id" => "triangle", "x" => 10, "y" => 20, "width" => 500, "height" => 600}

    support = %{
      "id" => "s1",
      "title" => "Document",
      "text" => "Observe les figures.",
      "image_ids" => ["shared"],
      "image_regions" => []
    }

    context = Map.put(context(), :supports, [support])

    slot =
      Map.merge(slot(), %{
        "support_id" => "s1",
        "answer_basis" => "document",
        "image_regions" => [crop],
        "text" => "Données de la question."
      })

    assert {:ok, spec} = ExerciseSpec.new(slot, context)
    assert spec.question["image_ids"] == ["triangle", "shared"]
    assert hd(spec.question["image_regions"]) == crop
    assert List.last(spec.question["image_regions"])["image_id"] == "shared"
    assert List.last(spec.question["image_regions"])["width"] == 1000
    assert spec.question["support_text"] == support["text"]
    assert spec.question["text"] == slot["text"]

    assert {:ok, restored} =
             spec |> ExerciseSpec.to_map() |> roundtrip() |> ExerciseSpec.from_map(context)

    assert restored == spec

    modified_support = put_in(context, [:supports, Access.at(0), "text"], "Document différent.")

    assert {:error, %BuildError{kind: :stale_dependency}} =
             ExerciseSpec.validate(spec, modified_support)
  end

  test "a shared text cannot remove an image and conflicting crops cannot silently overwrite it" do
    crop = %{"image_id" => "triangle", "x" => 0, "y" => 0, "width" => 500, "height" => 500}

    support = %{
      "id" => "s1",
      "title" => "Texte",
      "text" => "Document partagé",
      "image_ids" => [],
      "image_regions" => []
    }

    slot =
      Map.merge(slot(), %{
        "support_id" => "s1",
        "answer_basis" => "document",
        "image_regions" => [crop]
      })

    assert {:ok, spec} = ExerciseSpec.new(slot, Map.put(context(), :supports, [support]))
    assert spec.question["image_ids"] == ["triangle"]
    assert spec.question["image_regions"] == [crop]

    conflicting = Map.put(support, "image_ids", ["triangle"])

    assert {:error, %BuildError{kind: :invalid_contract}} =
             ExerciseSpec.new(slot, Map.put(context(), :supports, [conflicting]))
  end

  test "hashes and typed objects survive JSON serialization deterministically" do
    assert {:ok, spec} = ExerciseSpec.new(slot(), context())
    assert {:ok, same} = slot() |> Enum.reverse() |> Map.new() |> ExerciseSpec.new(context())
    assert same.hash == spec.hash
    assert {:ok, draft} = draft(spec)
    assert {:ok, exercise} = ExerciseDraft.build(spec, draft, context())

    assert {:ok, ^spec} =
             spec |> ExerciseSpec.to_map() |> roundtrip() |> ExerciseSpec.from_map(context())

    assert {:ok, ^draft} =
             draft |> ExerciseDraft.to_map() |> roundtrip() |> ExerciseDraft.from_map(spec)

    assert {:ok, ^exercise} =
             exercise
             |> ValidatedExercise.to_map()
             |> roundtrip()
             |> ValidatedExercise.from_map(context())

    falsely_approved =
      exercise |> ValidatedExercise.to_map() |> Map.put("pedagogical_audit", "approved")

    assert {:error, %BuildError{kind: :invalid_contract}} =
             ValidatedExercise.from_map(falsely_approved, context())
  end

  test "malformed inputs return typed failures instead of crashing or becoming valid exercises" do
    for bad <- [nil, [], 1, "question", %{}] do
      assert {:error, %BuildError{}} = ExerciseSpec.new(bad, context())
      assert {:error, %BuildError{}} = ExerciseSpec.from_map(bad, context())
      assert {:error, %BuildError{}} = ValidatedExercise.from_map(bad, context())
    end

    for {key, value} <- [
          {"image_regions", [nil]},
          {"source_page_ids", "course"},
          {"options", nil},
          {"points", 0},
          {"metadata", %{bad: :atom}}
        ] do
      assert {:error, %BuildError{}} = ExerciseSpec.new(Map.put(slot(), key, value), context())
    end

    assert {:ok, spec} = ExerciseSpec.new(slot(), context())

    for bad <- [nil, [], %{}, %{"spec_id" => spec.id, "spec_hash" => spec.hash, "prompt" => nil}] do
      assert {:error, %BuildError{}} = ExerciseDraft.new(spec, bad)
    end

    error =
      BuildError.new(:missing_dependency, :spec, "Image absente", details: %{"id" => "triangle"})

    assert %{"kind" => "missing_dependency", "retryable" => false} =
             error |> BuildError.to_map() |> roundtrip()
  end
end
