defmodule CaptainHomework.OpenAIPlanCheckpointTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.AI.OpenAI
  alias CaptainHomework.{Catalogues, Study}
  @moduletag capture_log: true

  setup do
    keys = [:openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:captain_homework, :ai_provider, OpenAI)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)

    lesson = lesson(profile())
    source = page(lesson)
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)

    Req.Test.stub(__MODULE__, fn conn ->
      response(conn, %{
        "entries" => [
          %{
            "kind" => "knowledge",
            "title" => "Membrane",
            "content" => source.text,
            "keywords" => ["cellule"],
            "source_page_ids" => ["p1"],
            "visual_page_ids" => [],
            "usable" => true
          }
        ]
      })
    end)

    assert {:ok, _} = Catalogues.prepare_page(source)

    question =
      question()
      |> Map.merge(%{
        "objective" => "Membrane",
        "skill" => "recall",
        "response_effort" => "direct",
        "answer_basis" => "knowledge",
        "expected_elements" => ["Délimitation de la cellule"],
        "source_page_ids" => [source.id],
        "support_id" => "",
        "image_ids" => []
      })

    %{lesson: lesson, source: source, plan: %{"questions" => [question], "supports" => []}}
  end

  test "an invalid full draft returns before any repair request", ctx do
    invalid = put_in(ctx.plan, ["questions", Access.at(0), "points"], 0)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["max_output_tokens"] >= 20_000
      send(owner, :planning_request)
      response(conn, invalid)
    end)

    assert {:error, {:invalid_plan, saved, reason}} =
             OpenAI.plan_control(ctx.lesson, [ctx.source], [], 1, "", [], ["long"])

    assert hd(saved["questions"])["points"] == 0
    assert is_map(Jason.decode!(saved["context"]))
    assert saved["image_ids"] == []
    assert is_binary(reason) and reason != ""
    assert_received :planning_request
    refute_received :planning_request
  end

  test "repair resumes a saved draft and reports a transport failure without retrying", ctx do
    rejected = %{"plan" => ctx.plan, "reason" => "Corrige uniquement le nombre de points."}
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      prompt = Jason.decode!(body)["input"] |> hd() |> Map.fetch!("content") |> hd()
      assert prompt["text"] =~ "Reprends ce contrôle déjà rédigé"
      assert prompt["text"] =~ Jason.encode!(ctx.plan)
      assert prompt["text"] =~ rejected["reason"]
      send(owner, :repair_request)
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert {:error, reason} =
             OpenAI.repair_control_plan(
               ctx.lesson,
               [ctx.source],
               [],
               1,
               "",
               [],
               ["long"],
               rejected
             )

    assert is_binary(reason)
    assert reason =~ "service IA"
    assert_received :repair_request
    refute_received :repair_request
  end

  test "repair returns publishable versioned questions only after complete validation", ctx do
    Req.Test.stub(__MODULE__, &response(&1, ctx.plan))

    assert {:ok, plan} =
             OpenAI.repair_control_plan(
               ctx.lesson,
               [ctx.source],
               [],
               1,
               "",
               [],
               ["long"],
               %{"plan" => ctx.plan, "reason" => "Corrige le barème."}
             )

    assert plan["version"] == CaptainHomework.Exams.Plan.version()
    assert {:ok, [question]} = CaptainHomework.Exams.Plan.ready_questions(plan)
    assert question["plan_id"] == "q1"
  end

  test "a rejected checkpoint reuses its selected context during repair", ctx do
    invalid = put_in(ctx.plan, ["questions", Access.at(0), "points"], 0)

    context =
      Jason.encode!(%{
        "catalogue" => [
          %{
            "kind" => "knowledge",
            "content" => "PINNED_COURSE_EVIDENCE",
            "source_page_ids" => [ctx.source.id],
            "visual_page_ids" => []
          }
        ],
        "source_kinds" => %{ctx.source.id => "lesson"}
      })

    invalid = Map.merge(invalid, %{"context" => context, "image_ids" => []})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      prompt =
        Jason.decode!(raw)["input"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")

      assert prompt =~ "PINNED_COURSE_EVIDENCE"
      assert length(Regex.scan(~r/PINNED_COURSE_EVIDENCE/, prompt)) == 1
      response(conn, ctx.plan)
    end)

    assert {:ok, repaired} =
             OpenAI.repair_control_plan(ctx.lesson, [ctx.source], [], 1, "", [], ["long"], %{
               "plan" => invalid,
               "reason" => "Points invalides"
             })

    assert repaired["context"] == context
  end

  test "the audit cannot use a hidden lesson OCR as proof of an exposed answer", ctx do
    question = ctx.plan["questions"] |> hd() |> Map.put("plan_id", "q1")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      schema =
        get_in(Jason.decode!(raw), [
          "text",
          "format",
          "schema",
          "properties",
          "reviews",
          "items",
          "properties"
        ])

      assert schema["exposure_source_id"]["type"] == "string"
      assert schema["exposure_quote"]["type"] == "string"

      response(conn, %{
        "reviews" => [
          %{
            "plan_id" => "q1",
            "actual_effort" => "direct",
            "actual_basis" => "knowledge",
            "consistent" => true,
            "answer_exposed" => true,
            "exposure_source_id" => ctx.source.id,
            "exposure_quote" => ctx.source.text,
            "reason" => "La définition est dans le cours."
          }
        ]
      })
    end)

    assert {:ok, [_accepted], []} =
             OpenAI.audit_response_effort([question], %{source_pages: [ctx.source]})
  end

  test "one malformed cloze and one invalid source are diagnosed together and repaired alone",
       ctx do
    good = hd(ctx.plan["questions"]) |> Map.put("plan_id", "q1")

    cloze =
      good
      |> Map.merge(%{
        "id" => "q2",
        "plan_id" => "q2",
        "type" => "cloze",
        "objective" => "Noyau",
        "expected_elements" => ["noyau"],
        "text" => "La cellule contient un {{1}}.",
        "slots" => ["{{1}}"],
        "prompt" => "Complète la phrase.",
        "answer" => "1: noyau"
      })

    third =
      good
      |> Map.merge(%{
        "id" => "q3",
        "plan_id" => "q3",
        "objective" => "Cytoplasme",
        "expected_elements" => ["cytoplasme"],
        "source_page_ids" => ["unknown"]
      })

    draft = %{"questions" => [good, cloze, third], "supports" => []}

    Req.Test.stub(__MODULE__, fn conn -> response(conn, draft) end)

    assert {:error, {:invalid_plan, saved, reason}} =
             OpenAI.plan_control(ctx.lesson, [ctx.source], [], 3, "", [], ["long", "cloze"])

    assert reason =~ "Question q2"
    assert reason =~ "Question q3"
    refute reason =~ "Question q1"

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      schema = get_in(Jason.decode!(raw), ["text", "format", "schema", "properties", "questions"])
      assert schema["type"] == "object"
      assert Enum.sort(schema["required"]) == ["q2", "q3"]
      refute Map.has_key?(schema["properties"], "q1")
      slots = get_in(schema, ["properties", "q2", "properties", "slots", "items"])
      assert Regex.match?(Regex.compile!(slots["pattern"]), "1")
      refute Regex.match?(Regex.compile!(slots["pattern"]), "{{1}}")

      response(conn, %{
        "questions" => [
          Map.put(third, "source_page_ids", [ctx.source.id]),
          Map.put(cloze, "slots", ["1"])
        ],
        "supports" => []
      })
    end)

    assert {:ok, repaired} =
             OpenAI.repair_control_plan(
               ctx.lesson,
               [ctx.source],
               [],
               3,
               "",
               [],
               ["long", "cloze"],
               %{"plan" => saved, "reason" => reason}
             )

    assert hd(repaired["questions"]) == hd(saved["questions"])
    assert Enum.map(repaired["questions"], & &1["id"]) == ["q1", "q2", "q3"]
    assert Enum.all?(repaired["questions"], &(&1["response_effort"] == "direct"))
  end

  test "retained legacy questions receive metadata without rewriting their content", ctx do
    kept = question() |> Map.put("plan_id", "retry-stable") |> Map.put("image_ids", [])

    metadata =
      hd(ctx.plan["questions"]) |> Map.drop(CaptainHomework.AI.QuestionContract.content_fields())

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      schema = get_in(Jason.decode!(raw), ["text", "format", "schema", "properties", "questions"])
      assert schema["required"] == ["retry-stable"]
      refute Map.has_key?(schema["properties"]["retry-stable"]["properties"], "prompt")
      response(conn, %{"questions" => %{"retry-stable" => metadata}, "supports" => []})
    end)

    assert {:ok, plan} =
             OpenAI.plan_control(ctx.lesson, [ctx.source], [], 1, "", [kept], ["long"])

    generated = hd(plan["questions"])
    assert generated["plan_id"] == "retry-stable"

    assert Map.take(generated, CaptainHomework.AI.QuestionContract.content_fields()) ==
             Map.take(
               Map.put_new(kept, "image_regions", []),
               CaptainHomework.AI.QuestionContract.content_fields()
             )

    assert generated["objective"] == "Membrane"
  end

  test "repair cannot overwrite a support still used by a valid question", ctx do
    good =
      hd(ctx.plan["questions"])
      |> Map.merge(%{
        "answer_basis" => "document",
        "support_id" => "s1",
        "text" => "Quel est le rôle de la membrane ?",
        "support_text" => "Texte original.",
        "support_title" => "La cellule",
        "image_regions" => [],
        "plan_id" => "q1"
      })

    bad =
      good
      |> Map.merge(%{
        "id" => "q2",
        "plan_id" => "q2",
        "objective" => "Noyau",
        "expected_elements" => ["noyau"],
        "points" => 0
      })

    support = %{
      "id" => "s1",
      "title" => "La cellule",
      "text" => "Texte original.",
      "image_ids" => []
    }

    base = %{"questions" => [good, bad], "supports" => [support]}

    Req.Test.stub(__MODULE__, fn conn ->
      response(conn, %{
        "questions" => [Map.put(bad, "points", 1)],
        "supports" => [Map.put(support, "text", "Texte modifié.")]
      })
    end)

    assert {:error, {:invalid_plan, saved, reason}} =
             OpenAI.repair_control_plan(ctx.lesson, [ctx.source], [], 2, "", [], ["long"], %{
               "plan" => base,
               "reason" => "points"
             })

    assert reason =~ "support partagé"
    assert Map.take(saved, ["questions", "supports"]) == base

    new_support = %{support | "id" => "s2", "text" => "Un autre texte."}

    Req.Test.stub(__MODULE__, fn conn ->
      response(conn, %{
        "questions" => [Map.merge(bad, %{"points" => 1, "support_id" => "s2"})],
        "supports" => [new_support]
      })
    end)

    assert {:ok, repaired} =
             OpenAI.repair_control_plan(ctx.lesson, [ctx.source], [], 2, "", [], ["long"], %{
               "plan" => base,
               "reason" => "points"
             })

    assert hd(repaired["questions"]) == good
    assert support in repaired["supports"]
    assert Map.put(new_support, "image_regions", []) in repaired["supports"]
  end

  test "diagnostics detect normalized duplicate answers and unknown images", ctx do
    first = hd(ctx.plan["questions"])

    second =
      first
      |> Map.merge(%{
        "id" => "q2",
        "objective" => "Une autre notion",
        "expected_elements" => ["  DÉLIMITATION DE LA CELLULE  "],
        "image_ids" => ["unknown"]
      })

    errors =
      CaptainHomework.Exams.Plan.diagnostics(
        %{"questions" => [first, second, nil], "supports" => []},
        ["q1", "q2"],
        ["long"],
        [ctx.source],
        []
      )

    assert Enum.any?(errors["q1"], &String.contains?(&1, "déjà évalués"))
    assert Enum.any?(errors["q2"], &String.contains?(&1, "Illustration"))
  end

  defp response(conn, plan) do
    plan =
      case plan do
        %{"questions" => questions} when is_list(questions) ->
          Map.put(
            plan,
            "questions",
            Map.new(questions, &{&1["id"], Map.drop(&1, ["id", "plan_id"])})
          )

        _ ->
          plan
      end

    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(plan)}]}
      ]
    })
  end
end
