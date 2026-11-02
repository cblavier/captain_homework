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

  defp response(conn, plan) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(plan)}]}
      ]
    })
  end
end
