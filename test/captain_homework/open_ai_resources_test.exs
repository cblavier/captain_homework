defmodule CaptainHomework.OpenAIResourcesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Catalogues, Repo, Study, Resources, Uploads}
  alias CaptainHomework.AI.OpenAI

  setup do
    keys = [:uploads_dir, :openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    dir = Path.join(System.tmp_dir!(), "catalogue-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)
    Application.put_env(:captain_homework, :openai_api_key, "test-only-api-key")
    Application.put_env(:captain_homework, :ai_provider, OpenAI)
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)

      File.rm_rf(dir)
    end)

    :ok
  end

  test "grading requests structured language corrections with explanations" do
    e = exam(lesson(profile()))

    annotation = %{
      "field" => "",
      "original" => "chat",
      "replacement" => "chats",
      "occurrence" => 1,
      "explanation" => "Le nom est au pluriel."
    }

    grade = %{
      "id" => "q1",
      "fraction" => 1,
      "feedback" => "Correct.",
      "language_errors" => [annotation]
    }

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      schema =
        get_in(body, ["text", "format", "schema", "properties", "grades", "items", "properties"])

      assert get_in(body, ["text", "format", "schema", "properties", "appreciation", "type"]) ==
               "string"

      assert schema["language_errors"]["items"]["properties"]["explanation"]["type"] == "string"
      prompt = get_in(body, ["input", Access.at(0), "content", Access.at(0), "text"])
      assert prompt =~ "indépendamment de la note"

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{
            "content" => [
              %{
                "type" => "output_text",
                "text" => Jason.encode!(%{"grades" => [grade], "appreciation" => "Bon travail."})
              }
            ]
          }
        ]
      })
    end)

    assert {:ok, %{"grades" => [^grade], "appreciation" => "Bon travail."}} = OpenAI.grade(e)
  end

  defp document(count) do
    l = lesson(profile())
    {:ok, resource} = Resources.create_url(l.profile_id, l.id, "https://example.com/course.pdf")
    resource = resource |> Ecto.Changeset.change(status: "ready") |> Repo.update!()

    pages =
      for n <- 1..count do
        key = "#{resource.id}-#{n}.png"
        File.write!(Uploads.path(key), "image #{n}")

        {:ok, page} =
          Study.add_page(l, %{
            resource_id: resource.id,
            kind: "resource",
            status: "ready",
            filename: "page-#{n}.png",
            storage_key: key,
            content_type: "image/png",
            text: "Texte intégral à ne pas renvoyer. " <> String.duplicate("Source #{n}. ", 100),
            document_kind: "activity"
          })

        page
      end

    {Study.get_lesson!(l.profile_id, l.id), resource, pages}
  end

  defp entry(page, attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "exercise",
        "title" => "La cellule",
        "keywords" => ["cellule"],
        "content" => "Observe la cellule et explique le rôle de la membrane.",
        "source_page_ids" => [page.id],
        "visual_page_ids" => [page.id],
        "usable" => true
      },
      attrs
    )
  end

  defp stub(catalogue, questions \\ []) do
    caller = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      properties = get_in(body, ["text", "format", "schema", "properties"])
      kind = if Map.has_key?(properties, "entries"), do: :catalogue, else: :generation
      send(caller, {kind, body})
      result = if kind == :catalogue, do: catalogue, else: %{"questions" => questions}

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)
  end

  test "example styles are cached and their images never enter generation requests" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source, %{"visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    File.write!(Uploads.path("style.png"), "original example image")

    {:ok, example} =
      Study.add_page(lesson, %{
        kind: "example",
        filename: "style.png",
        storage_key: "style.png",
        content_type: "image/png"
      })

    profile = %{
      "readable" => true,
      "question_types" => [%{"type" => "mcq", "count" => 4, "points" => 8}],
      "instruction_style" => "concise",
      "grouping" => "by_type",
      "response_length" => "short",
      "numbering" => "numeric"
    }

    caller = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      props = get_in(body, ["text", "format", "schema", "properties"])

      result =
        if Map.has_key?(props, "question_types") do
          send(caller, :style_analysis)
          assert Enum.any?(hd(body["input"])["content"], &(&1["type"] == "input_image"))
          profile
        else
          send(caller, :styled_generation)
          content = hd(body["input"])["content"]
          refute Enum.any?(content, &(&1["type"] == "input_image"))
          assert hd(content)["text"] =~ Jason.encode!(profile)
          %{"questions" => []}
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, ^profile} = CaptainHomework.ExampleStyles.prepare(example)
    assert_receive :style_analysis

    for _ <- 1..2 do
      assert {:ok, []} = OpenAI.generate(lesson, [source], [example], 2, "", [])
      assert_receive :styled_generation
      refute_received :style_analysis
    end

    saved = Repo.get!(Study.Page, example.id)
    assert saved.style_profile == profile
    assert saved.processing_progress == 100
    assert saved.processing_stage == nil
    File.write!(Uploads.path("style.png"), "replaced example image")
    assert {:ok, ^profile} = CaptainHomework.ExampleStyles.prepare(example)
    assert_receive :style_analysis
    refute Repo.get!(Study.Page, example.id).style_hash == saved.style_hash

    assert {:error, _} =
             CaptainHomework.ExampleStyles.validate(
               Map.put(profile, "lesson_content", "Not allowed")
             )
  end

  defp complete_question(id, type, source, attrs \\ %{}) do
    question(id, type)
    |> Map.merge(%{
      "plan_id" => id,
      "objective" => "Structure #{id}",
      "skill" => "recall",
      "response_effort" => "direct",
      "answer_basis" => "document",
      "expected_elements" => ["membrane #{id}"],
      "source_page_ids" => [source.id],
      "support_id" => "",
      "prompt" => "Nomme la structure #{id}.",
      "text" => "La membrane délimite la cellule.",
      "image_ids" => []
    })
    |> Map.merge(attrs)
  end

  defp response(conn, result) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
      ]
    })
  end

  defp review(id, attrs \\ %{}) do
    Map.merge(
      %{
        "plan_id" => id,
        "actual_effort" => "direct",
        "actual_basis" => "document",
        "answer_exposed" => true,
        "consistent" => true,
        "reason" => "Conforme"
      },
      attrs
    )
  end

  test "planner produces final questions with original images in one call" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source)]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = %{
      "questions" => [complete_question("q1", "long", source, %{"support_id" => "s1"})],
      "supports" => [
        %{"id" => "s1", "title" => "Cellule", "text" => "", "image_ids" => [source.id]}
      ]
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(calls, &(&1 + 1))
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(raw)["input"] |> hd() |> Map.fetch!("content")
      assert Enum.count(content, &(&1["type"] == "input_image")) == 1
      assert Enum.any?(content, &String.contains?(&1["text"] || "", source.id))
      assert hd(content)["text"] =~ "CONTRÔLE COMPLET"
      assert hd(content)["text"] =~ "inclus au moins une question"
      response(conn, plan)
    end)

    assert {:ok, result} = OpenAI.plan_control(lesson, [source], [], 1, "", [], ["long"])
    assert result["version"] == 2
    assert {:ok, [question]} = CaptainHomework.Exams.Plan.ready_questions(result)
    assert question["image_ids"] == [source.id]
    assert question["prompt"] == hd(plan["questions"])["prompt"]
    assert Agent.get(calls, & &1) == 1
  end

  test "numerous external exercises do not crowd course knowledge out of the context" do
    {lesson, resource, [source]} = document(1)

    external =
      for n <- 1..30,
          do:
            entry(source, %{
              "title" => "Exercice #{n}",
              "content" => String.duplicate("Texte externe. ", 150),
              "visual_page_ids" => []
            })

    stub(%{"entries" => external})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    course = page(lesson)
    course_entry = entry(course, %{"kind" => "knowledge", "visual_page_ids" => []})
    stub(%{"entries" => [course_entry]})
    assert {:ok, _} = Catalogues.prepare_page(course)
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)

    assert {:ok, content, [], []} = Catalogues.context(lesson, [source, course], [], 10, "", [])
    selected = Jason.decode!(content)
    assert course_entry in selected["catalogue"]
    assert Enum.any?(selected["catalogue"], &(&1 in external))
    assert selected["source_kinds"][course.id] == "lesson"
    assert selected["source_kinds"][source.id] == "resource"
  end

  test "audit sees only displayed images, diagram and hidden source evidence" do
    {_lesson, _resource, [image, unused]} = document(2)

    q =
      complete_question("q1", "long", image, %{
        "response_effort" => "short",
        "answer_basis" => "knowledge",
        "support_id" => "s1",
        "image_ids" => [image.id],
        "diagram" => %{"shapes" => [%{"id" => "1", "x" => 100, "y" => 20}]}
      })

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(raw)["input"] |> hd() |> Map.fetch!("content")
      prompt = hd(content)["text"]
      assert prompt =~ "Support qui dévoile la réponse"
      assert prompt =~ "Sources justificatives NON VISIBLES"
      assert prompt =~ "Preuve OCR"
      assert prompt =~ "shapes"
      refute prompt =~ "response_effort"
      refute prompt =~ "answer_basis"
      assert Enum.count(content, &(&1["type"] == "input_image")) == 1
      refute Jason.encode!(content) =~ unused.id
      refute prompt =~ "Support inutilisé"
      response(conn, %{"reviews" => [review("q1", %{"actual_effort" => "short"})]})
    end)

    assert {:ok, [], [_]} =
             OpenAI.audit_response_effort([q], %{
               supports: [
                 %{
                   "id" => "s1",
                   "text" => "Support qui dévoile la réponse",
                   "image_ids" => [image.id]
                 },
                 %{"id" => "unused", "text" => "Support inutilisé", "image_ids" => [unused.id]}
               ],
               images: [image, unused],
               source_pages: [%{id: image.id, kind: "lesson", text: "Preuve OCR"}]
             })
  end

  test "generation audits its first complete draft without a second writing call" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source, %{"visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    calls = start_supervised!({Agent, fn -> [] end})
    draft = complete_question("q1", "reading", source)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      props = get_in(Jason.decode!(raw), ["text", "format", "schema", "properties"])
      kind = if Map.has_key?(props, "reviews"), do: :audit, else: :plan
      Agent.update(calls, &(&1 ++ [kind]))

      result =
        if kind == :plan,
          do: %{"questions" => [draft], "supports" => []},
          else: %{"reviews" => [review("q1")]}

      response(conn, result)
    end)

    assert {:ok, exam} =
             CaptainHomework.Exams.generate(lesson.profile_id, lesson.id, 1, "",
               question_types: ["reading"]
             )

    assert exam.status == "in_progress"
    assert Agent.get(calls, & &1) == [:plan, :audit]
    assert hd(exam.questions)["prompt"] == draft["prompt"]
    assert hd(exam.questions)["verified_response_effort"] == "direct"
    assert hd(exam.questions)["verified_answer_basis"] == "document"
  end

  test "only a rejected question is repaired before the complete control is audited again" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source, %{"visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    calls = start_supervised!({Agent, fn -> [] end})
    draft = complete_question("q1", "reading", source)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      props = get_in(body, ["text", "format", "schema", "properties"])
      prompt = hd(hd(body["input"])["content"])["text"]

      kind =
        cond do
          Map.has_key?(props, "reviews") -> :audit
          String.contains?(prompt, "Corrige uniquement") -> :repair
          true -> :plan
        end

      history = Agent.get_and_update(calls, fn history -> {history, history ++ [kind]} end)

      result =
        case kind do
          :plan ->
            %{"questions" => [draft], "supports" => []}

          :audit ->
            actual = if history == [:plan], do: "developed", else: "direct"
            %{"reviews" => [review("q1", %{"actual_effort" => actual})]}

          :repair ->
            assert prompt =~ "effort constaté developed"

            %{
              "questions" => [Map.put(draft, "prompt", "Nomme uniquement la structure.")],
              "supports" => []
            }
        end

      response(conn, result)
    end)

    assert {:ok, exam} =
             CaptainHomework.Exams.generate(lesson.profile_id, lesson.id, 1, "",
               question_types: ["reading"]
             )

    assert exam.status == "in_progress"
    assert Agent.get(calls, & &1) == [:plan, :audit, :repair, :audit]
    assert hd(exam.questions)["prompt"] == "Nomme uniquement la structure."
  end

  test "invalid plans are repaired once and expose only a readable error" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source, %{"visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{
            "content" => [
              %{
                "type" => "output_text",
                "text" => Jason.encode!(%{"questions" => [], "supports" => []})
              }
            ]
          }
        ]
      })
    end)

    {:ok, exam} =
      CaptainHomework.Exams.generate(lesson.profile_id, lesson.id, 2, "",
        question_types: ["reading"]
      )

    assert Agent.get(counter, & &1) == 2
    assert exam.status == "generation_partial"
    assert exam.generation_errors == [CaptainHomework.AI.message(:invalid_plan)]
    refute hd(exam.generation_errors) =~ "identifiants"
  end

  test "a failed audit resumes saved drafts without paying for another plan" do
    {lesson, resource, [source]} = document(1)
    stub(%{"entries" => [entry(source, %{"visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    calls = start_supervised!({Agent, fn -> %{plans: 0, audits: 0} end})
    q = complete_question("q1", "reading", source)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      props = get_in(Jason.decode!(raw), ["text", "format", "schema", "properties"])

      if Map.has_key?(props, "reviews") do
        number =
          Agent.get_and_update(calls, fn state ->
            {state.audits + 1, %{state | audits: state.audits + 1}}
          end)

        if number == 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, "{}")
        else
          response(conn, %{"reviews" => [review("q1")]})
        end
      else
        Agent.update(calls, &%{&1 | plans: &1.plans + 1})
        response(conn, %{"questions" => [q], "supports" => []})
      end
    end)

    {:ok, partial} =
      CaptainHomework.Exams.generate(lesson.profile_id, lesson.id, 1, "",
        question_types: ["reading"]
      )

    assert partial.status == "generation_partial"
    assert partial.questions == []
    assert partial.generation_plan["audit_pending"]
    assert hd(partial.generation_plan["pending_drafts"])["prompt"] == q["prompt"]
    {:ok, complete} = CaptainHomework.Exams.resume_generation(lesson.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert Agent.get(calls, & &1) == %{plans: 1, audits: 2}
    assert hd(complete.questions)["verified_answer_basis"] == "document"
  end

  test "import prepares a persistent catalogue reused by subsequent controls" do
    l = lesson(profile())
    path = Uploads.path("input.png")

    File.write!(
      path,
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )
    )

    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, path, "fiche.png")
    caller = self()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      properties = get_in(body, ["text", "format", "schema", "properties"])

      result =
        cond do
          Map.has_key?(properties, "document_kind") ->
            progress = Repo.get!(Study.Resource, resource.id)
            assert progress.processing_progress == 30
            assert progress.processing_stage == "Lecture OCR — 0/1 pages"
            send(caller, :ocr)
            %{"text" => "La membrane délimite la cellule.", "document_kind" => "course"}

          Map.has_key?(properties, "entries") ->
            progress = Repo.get!(Study.Resource, resource.id)
            assert progress.processing_progress == 90
            assert progress.processing_stage == "Analyse pédagogique"
            send(caller, :indexed)

            [page] =
              Repo.all(
                from p in Study.Page,
                  where: p.resource_id == ^resource.id and p.kind == "resource"
              )

            %{"entries" => [entry(page)]}

          true ->
            send(caller, :generated)
            %{"questions" => []}
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok,
            %{
              status: "ready",
              catalogue: %{"entries" => [_]},
              processing_progress: 100,
              processing_stage: nil
            }} =
             Resources.process(resource.id)

    assert_receive :ocr
    assert_receive :indexed
    lesson = Study.get_lesson!(l.profile_id, l.id)
    pages = CaptainHomework.Exams.Illustrations.content_pages(lesson)
    for _ <- 1..2, do: assert({:ok, []} = OpenAI.generate(lesson, pages, [], 1, "", []))
    assert_receive :generated
    assert_receive :generated
    refute_receive :indexed
    refute_receive :ocr
  end

  test "large documents reuse the catalogue and transmit only selected text and visuals" do
    {lesson, resource, [page | _] = pages} = document(25)
    questions = [%{"image_ids" => [page.id]}]
    stub(%{"entries" => [entry(page)]}, questions)
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    assert_receive {:catalogue, index_request}

    assert Enum.all?(
             get_in(index_request, ["input", Access.at(0), "content"]),
             &(&1["type"] == "input_text")
           )

    for _ <- 1..2 do
      assert {:ok, ^questions} = OpenAI.generate(lesson, pages, [], 1, "", [])
      assert_receive {:generation, request}
      input = get_in(request, ["input", Access.at(0), "content"])
      assert length(Enum.filter(input, &(&1["type"] == "input_image"))) == 1
      refute hd(input)["text"] =~ "Texte intégral à ne pas renvoyer"
    end

    refute_receive {:catalogue, _}
    assert Repo.get!(Study.Resource, resource.id).catalogue_hash != nil
  end

  test "edited source invalidates only its catalogue" do
    {lesson, resource, [page]} = document(1)
    stub(%{"entries" => [entry(page)]})
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    assert_receive {:catalogue, _}
    old_hash = Repo.get!(Study.Resource, resource.id).catalogue_hash
    page |> Ecto.Changeset.change(text: "Texte corrigé sur la membrane") |> Repo.update!()
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    assert_receive {:catalogue, _}
    refute Repo.get!(Study.Resource, resource.id).catalogue_hash == old_hash
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    refute_receive {:catalogue, _}
    assert Study.get_lesson!(lesson.profile_id, lesson.id).resources != []
  end

  test "unknown support references are rejected without caching" do
    {_lesson, resource, [page]} = document(1)
    stub(%{"entries" => [entry(page, %{"visual_page_ids" => [Ecto.UUID.generate()]})]})
    assert {:error, _} = Catalogues.prepare_resource(resource)
    assert Repo.get!(Study.Resource, resource.id).catalogue == nil
  end

  test "questions cannot display a source image that was not transmitted" do
    {lesson, _resource, [page, other] = pages} = document(2)
    stub(%{"entries" => [entry(page)]}, [%{"image_ids" => [other.id]}])
    assert {:ok, []} = OpenAI.generate(lesson, pages, [], 1, "", [])
  end

  test "course page catalogues are reused and regenerated after text changes" do
    l = lesson(profile())
    page = page(l)
    stub(%{"entries" => [entry(page, %{"kind" => "knowledge", "visual_page_ids" => []})]})
    assert {:ok, _} = Catalogues.prepare_page(page)
    assert_receive {:catalogue, _}
    assert {:ok, _} = Catalogues.prepare_page(page)
    refute_receive {:catalogue, _}

    page
    |> Ecto.Changeset.change(text: "La cellule est délimitée par la membrane")
    |> Repo.update!()

    assert {:ok, _} = Catalogues.prepare_page(page)
    assert_receive {:catalogue, _}
    assert Repo.get!(Study.Page, page.id).catalogue_hash != nil
  end

  test "concurrent preparation shares one analysis" do
    {_lesson, resource, [page]} = document(1)
    Req.Test.set_req_test_to_shared()
    stub(%{"entries" => [entry(page)]})
    tasks = for _ <- 1..2, do: Task.async(fn -> Catalogues.prepare_resource(resource) end)
    for task <- tasks, do: assert({:ok, _} = Task.await(task))
    assert_receive {:catalogue, _}
    refute_receive {:catalogue, _}
  end

  test "supporting knowledge stays with its exercise and unavailable dependencies are excluded" do
    {lesson, _resource, [exercise_page, fact_page] = pages} = document(2)
    exercise = entry(exercise_page, %{"source_page_ids" => [exercise_page.id, fact_page.id]})

    fact =
      entry(fact_page, %{
        "kind" => "knowledge",
        "content" => "La membrane délimite la cellule.",
        "visual_page_ids" => []
      })

    unavailable = entry(fact_page, %{"title" => "Vidéo non disponible", "usable" => false})
    stub(%{"entries" => [exercise, fact, unavailable]})
    assert {:ok, content, _images, _} = Catalogues.context(lesson, pages, [], 1, "", [])
    selected = Jason.decode!(content)["catalogue"]
    assert exercise in selected
    assert fact in selected
    refute unavailable in selected
  end

  test "compact model page labels are resolved to persistent image identifiers" do
    {_lesson, resource, [page]} = document(1)
    compact = entry(page, %{"source_page_ids" => ["p1"], "visual_page_ids" => ["p1"]})
    stub(%{"entries" => [compact]})
    assert {:ok, %{"entries" => [stored]}} = Catalogues.prepare_resource(resource)
    assert stored["source_page_ids"] == [page.id]
    assert stored["visual_page_ids"] == [page.id]
  end
end
