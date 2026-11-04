defmodule CaptainHomework.Exams.ExercisePipelineTest do
  use CaptainHomework.DataCase, async: false

  import CaptainHomework.Fixtures

  alias CaptainHomework.{Exams, Repo, Study, Uploads}
  alias CaptainHomework.AI.{Call, OpenAI, ResourcePreflight, Trace}
  alias CaptainHomework.Exams.{BuildError, ExerciseConstruction, ExerciseSpec, Illustrations}

  setup do
    keys = [:uploads_dir, :openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    directory = Path.join(System.tmp_dir!(), "exercise-pipeline-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    Application.put_env(:captain_homework, :uploads_dir, directory)
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :ai_provider, OpenAI)
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)

      File.rm_rf(directory)
    end)

    lesson = lesson(profile())
    source = page(lesson)

    source =
      source
      |> Ecto.Changeset.change(text: "La membrane délimite la cellule.")
      |> Repo.update!()

    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)
    calls = start_supervised!({Agent, fn -> [] end})
    %{lesson: lesson, source: source, calls: calls}
  end

  defp catalogue(source) do
    %{
      "entries" => [
        %{
          "kind" => "knowledge",
          "title" => "Le rôle de la membrane",
          "content" => source.text,
          "keywords" => ["membrane", "cellule"],
          "source_page_ids" => [source.id],
          "visual_page_ids" => [],
          "usable" => true
        }
      ]
    }
  end

  defp specification(source) do
    %{
      "type" => "definition",
      "task" => "Nommer l'élément qui délimite la cellule, en un mot ou groupe de mots.",
      "objective" => "Rôle de la membrane",
      "skill" => "recall",
      "response_effort" => "direct",
      "answer_basis" => "knowledge",
      "expected_elements" => ["la membrane"],
      "source_page_ids" => [source.id],
      "support_id" => "",
      "image_ids" => [],
      "image_regions" => [],
      "text" => "",
      "options" => [],
      "slots" => [],
      "diagram" => nil,
      "answer" => "La membrane.",
      "rubric" => "Identifier la membrane comme l'élément qui délimite la cellule.",
      "points" => 2
    }
  end

  defp response(conn, result) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
      ]
    })
  end

  defp request_stage(properties) do
    question_fields =
      case get_in(properties, ["questions", "properties"]) do
        questions when is_map(questions) ->
          questions |> Map.values() |> hd() |> Map.get("properties")

        _ ->
          %{}
      end

    cond do
      Map.has_key?(properties, "entries") ->
        :catalogue

      Map.has_key?(properties, "included_ids") ->
        :feasibility

      Map.has_key?(properties, "reviews") ->
        :audit

      Map.has_key?(question_fields, "task") ->
        :specification

      Map.has_key?(question_fields, "spec_hash") ->
        :construction

      Map.has_key?(properties, "supports") ->
        :specification

      true ->
        :unexpected
    end
  end

  defp stub(context, callback) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(raw)
      properties = get_in(request, ["text", "format", "schema", "properties"])
      stage = request_stage(properties)
      Agent.update(context.calls, &(&1 ++ [stage]))
      result = callback.(stage, properties, request)
      response(conn, result)
    end)
  end

  defp draft(properties, attrs \\ %{}, id \\ "q1") do
    fields = get_in(properties, ["questions", "properties", id, "properties"])

    Map.merge(
      %{
        "spec_id" => hd(fields["spec_id"]["enum"]),
        "spec_hash" => hd(fields["spec_hash"]["enum"]),
        "prompt" => "Quel élément délimite la cellule ?"
      },
      attrs
    )
  end

  defp accepted_review do
    %{
      "reviews" => [
        %{
          "plan_id" => "q1",
          "actual_effort" => "direct",
          "actual_basis" => "knowledge",
          "answer_exposed" => false,
          "consistent" => true,
          "reason" => "La consigne demande exactement la connaissance prévue au barème."
        }
      ]
    }
  end

  test "one classic question is specified, drafted with locked content, then audited", context do
    slot = specification(context.source)

    stub(context, fn
      :catalogue, _, _ ->
        catalogue(context.source)

      :specification, properties, _ ->
        fields = get_in(properties, ["questions", "properties", "q1", "properties"])
        assert fields["task"]["type"] == "string"
        refute Map.has_key?(fields, "prompt")
        assert fields["source_page_ids"]["items"]["enum"] == [context.source.id]
        %{"questions" => %{"q1" => slot}, "supports" => []}

      :construction, properties, _ ->
        fields = get_in(properties, ["questions", "properties", "q1", "properties"])
        assert Enum.sort(Map.keys(fields)) == ~w(prompt spec_hash spec_id)
        %{"questions" => %{"q1" => draft(properties)}}

      :audit, _, request ->
        prompt = get_in(request, ["input", Access.at(0), "content", Access.at(0), "text"])
        assert prompt =~ "Quel élément délimite la cellule ?"
        assert prompt =~ slot["answer"]
        assert prompt =~ slot["rubric"]
        accepted_review()

      unexpected, _, _ ->
        flunk("Unexpected API stage: #{inspect(unexpected)}")
    end)

    assert {:ok, exam} =
             Exams.generate(context.lesson.profile_id, context.lesson.id, 1, "",
               question_types: question_type_ids(["definition"])
             )

    assert exam.status == "in_progress", inspect(exam.generation_errors)
    assert Agent.get(context.calls, & &1) == [:catalogue, :specification, :construction, :audit]
    assert exam.generation_plan["workflow"] == "contract_v1"
    refute exam.generation_plan["construction_pending"]
    assert [question] = exam.questions
    assert question["prompt"] == "Quel élément délimite la cellule ?"

    for key <- ~w(type answer rubric points options slots diagram text source_page_ids image_ids) do
      assert question[key] == slot[key], "Drafting changed locked field #{key}"
    end

    spec = exam.generation_plan["exercise_specs"]["q1"]
    assert question["exercise_spec_hash"] == spec["hash"]
    assert question["exercise_spec_id"] == "q1"
    assert question["structural_validation"] == "valid"
  end

  test "a drafting response cannot change the locked answer or trigger a repair loop", context do
    stub(context, fn
      :catalogue, _, _ ->
        catalogue(context.source)

      :specification, _, _ ->
        %{"questions" => %{"q1" => specification(context.source)}, "supports" => []}

      :construction, properties, _ ->
        %{"questions" => %{"q1" => draft(properties, %{"answer" => "Le noyau."})}}

      unexpected, _, _ ->
        flunk("No audit or repair may follow an invalid draft: #{inspect(unexpected)}")
    end)

    assert {:ok, exam} =
             Exams.generate(context.lesson.profile_id, context.lesson.id, 1, "",
               question_types: question_type_ids(["definition"])
             )

    assert exam.status == "generation_partial"
    assert exam.questions == []
    assert Agent.get(context.calls, & &1) == [:catalogue, :specification, :construction]
    assert Enum.any?(exam.generation_errors, &String.contains?(&1, "Seule la consigne"))
    assert exam.generation_plan["exercise_specs"]["q1"]["question"]["answer"] == "La membrane."
  end

  test "a failed batch checkpoints its valid question and resumes only the missing draft",
       context do
    source =
      context.source
      |> Ecto.Changeset.change(text: "La membrane délimite la cellule. Le noyau contient l'ADN.")
      |> Repo.update!()

    context = %{
      context
      | source: source,
        lesson: Study.get_lesson!(context.lesson.profile_id, context.lesson.id)
    }

    second =
      specification(source)
      |> Map.merge(%{
        "task" => "Nommer l'élément de la cellule qui contient l'ADN.",
        "objective" => "Rôle du noyau",
        "expected_elements" => ["le noyau"],
        "answer" => "Le noyau.",
        "rubric" => "Identifier le noyau comme l'élément contenant l'ADN."
      })

    stub(context, fn
      :catalogue, _, _ ->
        catalogue(source)

      :specification, _, _ ->
        %{"questions" => %{"q1" => specification(source), "q2" => second}, "supports" => []}

      :construction, properties, _ ->
        ids = properties["questions"]["properties"] |> Map.keys() |> Enum.sort()

        case ids do
          ["q1", "q2"] ->
            %{
              "questions" => %{
                "q1" => draft(properties),
                "q2" => draft(properties, %{"answer" => "Réponse injectée"}, "q2")
              }
            }

          ["q2"] ->
            %{
              "questions" => %{
                "q2" => draft(properties, %{"prompt" => "Quel élément contient l'ADN ?"}, "q2")
              }
            }
        end

      unexpected, _, _ ->
        flunk("Unexpected request while resuming construction: #{inspect(unexpected)}")
    end)

    assert {:ok, plan} =
             OpenAI.plan_exercises(context.lesson, [source], [], 2, "", [], ["definition"])

    owner = self()
    checkpoint = fn saved -> send(owner, {:checkpoint, saved}) end

    assert {:error, %BuildError{kind: :invalid_draft}} =
             ExerciseConstruction.run(context.lesson, plan, [], checkpoint)

    assert_receive {:checkpoint, saved}
    assert Map.keys(saved["built_questions"]) == ["q1"]
    assert saved["construction_pending"]
    retained = saved["built_questions"]["q1"]

    assert {:ok, [first, second], completed} =
             ExerciseConstruction.run(context.lesson, saved, [], checkpoint)

    assert first == retained
    assert second["prompt"] == "Quel élément contient l'ADN ?"
    assert second["answer"] == "Le noyau."
    refute completed["construction_pending"]

    assert Agent.get(context.calls, & &1) == [
             :catalogue,
             :specification,
             :construction,
             :construction
           ]
  end

  test "four contracts draft in concurrent batches with coordinated checkpoints and exam traces",
       context do
    resource =
      Repo.insert!(%Study.Resource{
        lesson_id: context.lesson.id,
        filename: "Figure commune",
        status: "ready"
      })

    figure =
      Repo.insert!(%Study.Page{
        lesson_id: context.lesson.id,
        resource_id: resource.id,
        kind: "resource",
        filename: "figure.png",
        storage_key: "figure.png",
        content_type: "image/png",
        text: "Figure utilisée par les quatre exercices.",
        status: "ready"
      })

    File.write!(
      Uploads.path(figure.storage_key),
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )
    )

    lesson = Study.get_lesson!(context.lesson.profile_id, context.lesson.id)
    trace_exam = exam(lesson, [])
    ids = ~w(q3 q1 q4 q2)
    images = ResourcePreflight.available_images(lesson, [])
    sources = Illustrations.content_pages(lesson)
    contract_context = %{sources: sources, images: images, supports: [], types: ["reading"]}

    slots =
      Enum.map(ids, fn id ->
        specification(figure)
        |> Map.merge(%{
          "id" => id,
          "type" => "reading",
          "answer_basis" => "document",
          "objective" => "Observation #{id}",
          "expected_elements" => ["Élément #{id}"],
          "image_ids" => [figure.id]
        })
      end)

    specs =
      Map.new(slots, fn slot ->
        assert {:ok, spec} = ExerciseSpec.new(slot, contract_context)
        {spec.id, ExerciseSpec.to_map(spec)}
      end)

    plan = %{
      "questions" => slots,
      "supports" => [],
      "types" => ["reading"],
      "exercise_specs" => specs,
      "built_questions" => %{},
      "construction_pending" => true,
      "context" =>
        Jason.encode!(%{"catalogue" => [], "source_kinds" => %{figure.id => "resource"}})
    }

    owner = self()
    release_token = make_ref()

    stub(context, fn :construction, properties, request ->
      batch_ids = properties["questions"]["properties"] |> Map.keys() |> Enum.sort()

      image_inputs =
        hd(request["input"])["content"] |> Enum.filter(&(&1["type"] == "input_image"))

      send(owner, {:construction_started, self(), batch_ids, Trace.context(), image_inputs})

      receive do
        {:release, ^release_token} -> :ok
      end

      %{
        "questions" =>
          Map.new(batch_ids, fn id ->
            {id, draft(properties, %{"prompt" => "Observe la figure pour l'exercice #{id}."}, id)}
          end)
      }
    end)

    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Trace.with_exam(trace_exam.id, fn ->
          Trace.with_progress(
            fn _, _ -> send(owner, {:unexpected_worker_progress, self()}) end,
            fn ->
              ExerciseConstruction.run(lesson, plan, [], fn checkpoint ->
                send(
                  owner,
                  {:checkpoint, self(), Map.keys(checkpoint["built_questions"]) |> Enum.sort()}
                )
              end)
            end
          )
        end)
      end)

    assert_receive {:construction_started, first_worker, first_ids, first_trace, first_images},
                   2_000

    assert_receive {:construction_started, second_worker, second_ids, second_trace,
                    second_images},
                   2_000

    refute first_worker == second_worker
    assert Enum.sort([length(first_ids), length(second_ids)]) == [1, 3]
    assert Enum.sort(first_ids ++ second_ids) == Enum.sort(ids)
    assert first_trace == %{exam_id: trace_exam.id}
    assert second_trace == first_trace
    assert length(first_images) == 1
    assert second_images == first_images
    refute_received {:checkpoint, _, _}
    refute_received {:unexpected_worker_progress, _}

    {single_worker, group_worker} =
      if first_ids == ["q4"],
        do: {first_worker, second_worker},
        else: {second_worker, first_worker}

    coordinator = task.pid
    send(single_worker, {:release, release_token})
    assert_receive {:checkpoint, ^coordinator, ["q4"]}, 2_000
    refute_received {:checkpoint, _, _}

    send(group_worker, {:release, release_token})
    assert_receive {:checkpoint, ^coordinator, ["q1", "q2", "q3", "q4"]}, 2_000
    assert {:ok, questions, completed} = Task.await(task, 2_000)
    assert Enum.map(questions, & &1["plan_id"]) == ids
    assert Enum.all?(questions, &(&1["image_ids"] == [figure.id]))
    assert map_size(completed["built_questions"]) == 4
    refute completed["construction_pending"]
    refute_received {:unexpected_worker_progress, _}

    calls = Repo.all(Call) |> Enum.filter(&(&1.exam_id == trace_exam.id))
    assert length(calls) == 2

    assert Enum.all?(
             calls,
             &(&1.stage == "construction" and &1.status == "completed" and &1.image_count == 1)
           )
  end

  test "a retained legacy question acquires a contract without rewriting or replacing its assets",
       context do
    image_id = Ecto.UUID.generate()

    image = %{
      "source_page_id" => image_id,
      "storage_key" => "retained.png",
      "content_type" => "image/png"
    }

    audio = %{
      "id" => Ecto.UUID.generate(),
      "storage_key" => "retained.wav",
      "content_type" => "audio/wav"
    }

    File.write!(
      Uploads.path(image["storage_key"]),
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )
    )

    File.write!(Uploads.path(audio["storage_key"]), "retained audio")

    retained =
      specification(context.source)
      |> Map.delete("task")
      |> Map.merge(%{
        "id" => Ecto.UUID.generate(),
        "origin_id" => "legacy-origin",
        "plan_id" => "q1",
        "prompt" => "Quel élément délimite la cellule ?",
        "image_ids" => [image_id],
        "images" => [image],
        "audio" => audio
      })
      |> Map.drop(["audio_script", "image_regions"])

    stub(context, fn
      :catalogue, _, _ ->
        catalogue(context.source)

      :specification, properties, _ ->
        fields = properties["questions"]["properties"]["q1"]["properties"]
        refute Map.has_key?(fields, "task")
        refute Map.has_key?(fields, "prompt")
        refute Map.has_key?(fields, "answer")

        metadata =
          specification(context.source)
          |> Map.put("audio_script", nil)
          |> Map.take(Map.keys(fields))

        %{"questions" => %{"q1" => metadata}, "supports" => []}

      :audit, _, _ ->
        accepted_review()

      unexpected, _, _ ->
        flunk("Retained work must not be drafted again: #{inspect(unexpected)}")
    end)

    assert {:ok, plan} =
             OpenAI.plan_exercises(context.lesson, [context.source], [], 1, "", [retained], [
               "definition"
             ])

    spec = plan["exercise_specs"]["q1"]
    assert spec["task"] == retained["prompt"]
    assert spec["initial_prompt"] == retained["prompt"]
    assert spec["question"]["audio_script"] == nil
    assert spec["question"]["image_regions"] == []

    assert {:ok, [built], plan} =
             ExerciseConstruction.run(context.lesson, plan, [retained], fn _ -> :ok end)

    assert built["prompt"] == retained["prompt"]
    assert Agent.get(context.calls, & &1) == [:catalogue, :specification]

    pending =
      plan
      |> Map.put("audit_pending", true)
      |> Map.put("pending_drafts", [built])

    exam =
      exam(context.lesson, [retained])
      |> Ecto.Changeset.change(
        status: "generation_partial",
        instructions: "",
        generation_target: 1,
        generation_plan: pending
      )
      |> Repo.update!()

    assert {:ok, complete} = Exams.resume_generation(context.lesson.profile_id, exam.id)
    assert complete.status == "in_progress", inspect(complete.generation_errors)
    assert [question] = complete.questions
    assert question["id"] == retained["id"]
    assert question["origin_id"] == retained["origin_id"]
    assert question["images"] == retained["images"]
    assert question["audio"] == retained["audio"]
    assert question["exercise_spec_hash"] == spec["hash"]
    assert File.regular?(Uploads.path(image["storage_key"]))
    assert File.read!(Uploads.path(audio["storage_key"])) == "retained audio"
    assert Agent.get(context.calls, & &1) == [:catalogue, :specification, :audit]
  end

  for {status, instructions, reason} <- [
        {"incompatible", "Évalue uniquement les fractions, sans question sur la cellule.",
         "Le cours disponible traite de la cellule et ne contient aucune notion sur les fractions."},
        {"needs_clarification", "Évalue uniquement l'autre chapitre.",
         "Précise quel chapitre tu désignes par « l'autre chapitre »."}
      ] do
    @status status
    @instructions instructions
    @reason reason

    test "#{status} instructions stop before specification or construction", context do
      stub(context, fn
        :catalogue, _, _ ->
          catalogue(context.source)

        :feasibility, properties, _ ->
          assert properties["status"]["enum"] == [
                   "compatible",
                   "incompatible",
                   "needs_clarification"
                 ]

          %{
            "status" => @status,
            "reason" => @reason,
            "included_ids" => [],
            "evidence_ids" => [0],
            "use_examples" => false
          }

        unexpected, _, _ ->
          flunk("Refused instructions must stop before planning: #{inspect(unexpected)}")
      end)

      assert {:ok, exam} =
               Exams.generate(context.lesson.profile_id, context.lesson.id, 1, @instructions,
                 question_types: question_type_ids(["definition"])
               )

      assert exam.status == "generation_partial"
      assert exam.questions == []
      refute Map.has_key?(exam.generation_plan, "exercise_specs")
      assert exam.generation_plan["build_error"]["stage"] == "instructions"
      assert exam.generation_plan["build_error"]["retryable"] == false
      assert Agent.get(context.calls, & &1) == [:catalogue, :feasibility]
      assert Enum.any?(exam.generation_errors, &String.contains?(&1, @reason))
    end
  end
end
