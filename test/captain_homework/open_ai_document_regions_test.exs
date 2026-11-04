defmodule CaptainHomework.OpenAIDocumentRegionsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.AI.OpenAI
  alias CaptainHomework.{Catalogues, Study}

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

    :ok
  end

  test "planning never requests crop coordinates for independent or shared documents" do
    lesson = lesson(profile())
    source = page(lesson)
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)

    Req.Test.stub(__MODULE__, fn conn ->
      respond(conn, %{
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
        "image_ids" => [],
        "image_regions" => []
      })
      |> Map.drop(["id", "plan_id"])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      properties = get_in(body, ["text", "format", "schema", "properties"])

      independent =
        get_in(properties, ["questions", "properties", "q1", "properties", "image_regions"])

      shared = get_in(properties, ["supports", "items", "properties", "image_regions"])
      assert independent == nil
      assert shared == nil

      prompt = get_in(body, ["input", Access.at(0), "content", Access.at(0), "text"])
      assert prompt =~ "Les descriptions OCR et les analyses du catalogue"
      assert prompt =~ "légende et échelle d'une carte"
      assert prompt =~ "auteur, date, source et contexte nécessaires"
      respond(conn, %{"questions" => %{"q1" => question}, "supports" => []})
    end)

    assert {:ok, plan} = OpenAI.plan_control(lesson, [source], [], 1, "", [], ["long"])
    assert hd(plan["questions"])["image_regions"] == []
  end

  test "content and paraphrase defects still reject a question" do
    q = documentary_question()

    for {field, value, diagnostic} <- [
          {"content_consistent", false, "défaut pédagogique"},
          {"visual_paraphrase", true, "paraphrase le document"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        schema =
          get_in(Jason.decode!(raw), [
            "text",
            "format",
            "schema",
            "properties",
            "reviews",
            "items"
          ])

        for flag <- ~w(content_consistent visual_paraphrase) do
          assert flag in schema["required"]
          assert schema["properties"][flag] == %{"type" => "boolean"}
        end

        respond(conn, %{"reviews" => [Map.put(document_review(), field, value)]})
      end)

      assert {:ok, [], [error]} = OpenAI.audit_response_effort([q])
      assert error =~ diagnostic
    end
  end

  test "an authentic history source remains valid when its text contains the requested evidence" do
    q = documentary_question()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["reasoning"] == %{"effort" => "low"}
      assert body["max_output_tokens"] == 4_000
      respond(conn, %{"reviews" => [document_review()]})
    end)

    assert {:ok, [accepted], []} = OpenAI.audit_response_effort([q])
    assert accepted["text"] == q["text"]
    assert accepted["verified_answer_basis"] == "document"
  end

  defp documentary_question do
    question("q1", "reading")
    |> Map.merge(%{
      "plan_id" => "q1",
      "prompt" => "Quels droits cet article affirme-t-il ? Cite le passage pertinent.",
      "text" =>
        "Déclaration des droits de l'homme et du citoyen, 1789, article 1 : « Les hommes naissent et demeurent libres et égaux en droits. »",
      "answer" => "La liberté et l'égalité en droits : « libres et égaux en droits ».",
      "rubric" => "La liberté et l'égalité sont citées avec le passage qui les affirme.",
      "response_effort" => "direct",
      "answer_basis" => "document",
      "image_ids" => [],
      "support_id" => ""
    })
  end

  defp document_review do
    %{
      "plan_id" => "q1",
      "actual_effort" => "direct",
      "actual_basis" => "document",
      "answer_exposed" => false,
      "exposure_source_id" => "",
      "exposure_quote" => "",
      "document_complete" => true,
      "document_focused" => true,
      "visual_paraphrase" => false,
      "consistent" => true,
      "reason" => "Le texte source permet de relever et citer les informations demandées."
    }
  end

  defp respond(conn, result) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [%{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}]
    })
  end
end
