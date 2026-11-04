defmodule CaptainHomework.CustomInstructionsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Catalogues, Exams, Repo, Study}
  alias CaptainHomework.AI.OpenAI
  alias CaptainHomework.Exams.{Instructions, Plan}
  @moduletag capture_log: true
  @instructions "Ignore les activités et les contrôles d'exemple. Fais uniquement des définitions brèves du cours."

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

    l = lesson(profile())
    course = page(l)

    resource =
      Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "Activités", status: "ready"})

    activity =
      page(l)
      |> Ecto.Changeset.change(
        kind: "resource",
        resource_id: resource.id,
        document_kind: "activity",
        text: "ACTIVITY_ONLY_CONTENT"
      )
      |> Repo.update!()

    example =
      page(l)
      |> Ecto.Changeset.change(kind: "example", storage_key: "missing-example.png")
      |> Repo.update!()

    Req.Test.stub(
      __MODULE__,
      &response(&1, %{"entries" => [entry(course, "knowledge", course.text)]})
    )

    assert {:ok, _} = Catalogues.prepare_page(course)

    Req.Test.stub(
      __MODULE__,
      &response(&1, %{"entries" => [entry(activity, "exercise", activity.text)]})
    )

    assert {:ok, _} = Catalogues.prepare_resource(resource)
    l = Study.get_lesson!(l.profile_id, l.id)
    %{lesson: l, course: course, activity: activity, example: example}
  end

  test "excluded activities and examples stay out of generation and default quotas yield", ctx do
    owner = self()
    plan = drafted_plan(ctx.course)

    Req.Test.stub(__MODULE__, fn conn ->
      {conn, body, prompt, properties} = request(conn)
      assert body["instructions"] =~ "priorité pédagogique maximale"
      assert prompt =~ @instructions

      cond do
        properties["included_ids"] ->
          assert prompt =~ "ACTIVITY_ONLY_CONTENT"
          send(owner, :selection)
          response(conn, %{"included_ids" => [0], "use_examples" => false})

        properties["questions"] ->
          refute prompt =~ "ACTIVITY_ONLY_CONTENT"
          refute prompt =~ ctx.activity.id
          assert prompt =~ "aucune proportion n’est imposée"
          send(owner, :draft)
          response(conn, plan)

        properties["reviews"] ->
          assert prompt =~ "consistent=false"
          refute prompt =~ "ACTIVITY_ONLY_CONTENT"

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          send(owner, :audit)
          response(conn, %{"reviews" => Enum.map(questions, &review/1)})
      end
    end)

    assert {:ok, exam} =
             Exams.generate(ctx.lesson.profile_id, ctx.lesson.id, 3, @instructions,
               question_types: question_type_ids(["definition", "long"])
             )

    assert exam.status == "in_progress"
    assert_received :selection
    assert_received :draft
    assert_received :audit
    assert Enum.all?(exam.questions, &(&1["source_page_ids"] == [ctx.course.id]))

    assert Enum.all?(
             exam.questions,
             &(&1["response_effort"] == "direct" and &1["answer_basis"] == "knowledge")
           )

    assert exam.generation_plan["styles"] == []
    assert exam.generation_plan["slot_constraints"] == nil
    assert exam.generation_plan["custom_instructions"] == @instructions
    assert exam.generation_plan["allowed_source_page_ids"] == [ctx.course.id]
    assert exam.generation_plan["question_ids"] == ~w(q1 q2 q3)

    assert :ok =
             Plan.validate(plan, 3, ["definition", "long"], [ctx.course, ctx.activity], [])

    # Repair uses the saved source restrictions and author instructions, not default quotas.
    [slot | _] = exam.generation_plan["questions"]

    Req.Test.stub(__MODULE__, fn conn ->
      {conn, _, prompt, _} = request(conn)
      assert prompt =~ @instructions
      assert prompt =~ "Diagnostics techniques subordonnés"
      refute prompt =~ "ACTIVITY_ONLY_CONTENT"
      response(conn, %{"questions" => [slot], "supports" => []})
    end)

    assert {:ok, [_], repaired} =
             OpenAI.generate_planned(
               ctx.lesson,
               exam.generation_plan,
               [slot],
               Instructions.compose(@instructions, "Réparer le barème."),
               []
             )

    assert repaired["question_ids"] == ~w(q1 q2 q3)

    Req.Test.stub(__MODULE__, fn conn ->
      response(conn, %{
        "questions" => [Map.put(slot, "source_page_ids", [ctx.activity.id])],
        "supports" => []
      })
    end)

    assert {:error, _} =
             OpenAI.generate_planned(
               ctx.lesson,
               exam.generation_plan,
               [slot],
               Instructions.compose(@instructions, "Réessayer."),
               []
             )
  end

  test "an empty or invalid content selection fails instead of reverting to excluded sources",
       ctx do
    for ids <- [[], [99], [-1], [0, 0]] do
      Req.Test.stub(__MODULE__, fn conn ->
        {conn, _, _, properties} = request(conn)
        assert properties["included_ids"]
        response(conn, %{"included_ids" => ids, "use_examples" => false})
      end)

      assert {:error, _} =
               OpenAI.plan_control(
                 ctx.lesson,
                 [ctx.course, ctx.activity],
                 [ctx.example],
                 3,
                 @instructions,
                 [],
                 ["definition", "long"]
               )
    end
  end

  test "the audit rejects questions violating custom instructions", ctx do
    q = drafted_plan(ctx.course)["questions"] |> hd() |> Map.put("plan_id", "q1")

    Req.Test.stub(__MODULE__, fn conn ->
      {conn, _, prompt, _} = request(conn)
      assert prompt =~ @instructions

      response(conn, %{
        "reviews" => [
          review(q)
          |> Map.merge(%{
            "consistent" => false,
            "reason" => "La question reprend une activité exclue."
          })
        ]
      })
    end)

    assert {:ok, [], [reason]} =
             OpenAI.audit_response_effort([q], %{
               source_pages: [ctx.course],
               custom_instructions: @instructions
             })

    assert reason =~ "activité exclue"
  end

  test "technical repair feedback never becomes author instructions", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      {conn, _, prompt, properties} = request(conn)
      assert properties["included_ids"]
      assert prompt =~ @instructions
      refute prompt =~ "FORCE_ACTIVITY_DIAGNOSTIC"
      response(conn, %{"included_ids" => [0], "use_examples" => false})
    end)

    assert {:ok, content, [], []} =
             Catalogues.context(
               ctx.lesson,
               [ctx.course, ctx.activity],
               [],
               3,
               Instructions.compose(@instructions, "FORCE_ACTIVITY_DIAGNOSTIC"),
               []
             )

    refute content =~ "ACTIVITY_ONLY_CONTENT"
  end

  defp drafted_plan(course) do
    %{
      "questions" =>
        Enum.map(1..3, fn n ->
          question("q#{n}", "definition")
          |> Map.merge(%{
            "prompt" => "Définis la notion #{n}.",
            "objective" => "Notion #{n}",
            "skill" => "recall",
            "expected_elements" => ["Notion #{n}"],
            "source_page_ids" => [course.id],
            "response_effort" => "direct",
            "answer_basis" => "knowledge",
            "support_id" => "",
            "image_ids" => []
          })
        end),
      "supports" => []
    }
  end

  defp entry(page, kind, content) do
    %{
      "kind" => kind,
      "title" => "La cellule",
      "content" => content,
      "keywords" => ["cellule"],
      "usable" => true,
      "source_page_ids" => [page.id],
      "visual_page_ids" => []
    }
  end

  defp review(q) do
    %{
      "plan_id" => q["plan_id"],
      "actual_effort" => "direct",
      "actual_basis" => "knowledge",
      "answer_exposed" => false,
      "exposure_source_id" => "",
      "exposure_quote" => "",
      "consistent" => true,
      "reason" => "Conforme."
    }
  end

  defp request(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(raw)
    prompt = body["input"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
    {conn, body, prompt, get_in(body, ["text", "format", "schema", "properties"])}
  end

  defp response(conn, result) do
    result =
      case result do
        %{"questions" => questions, "supports" => _} when is_list(questions) ->
          Map.put(
            result,
            "questions",
            Map.new(questions, &{&1["id"], Map.drop(&1, ["id", "plan_id"])})
          )

        _ ->
          result
      end

    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [%{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}]
    })
  end
end
