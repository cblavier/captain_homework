defmodule CaptainHomework.OpenAISelectiveAuditTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.AI.OpenAI

  setup do
    keys = [:uploads_dir, :openai_api_key, :openai_request_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    dir = Path.join(System.tmp_dir!(), "selective-audit-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "map.png"),
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6K1cAAAAASUVORK5CYII="
      )
    )

    Application.put_env(:captain_homework, :uploads_dir, dir)
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)

      File.rm_rf(dir)
    end)

    %{
      image: %{
        id: "map",
        filename: "map.png",
        storage_key: "map.png",
        content_type: "image/png",
        kind: "resource",
        resource_id: "resource"
      }
    }
  end

  test "only pedagogical defects request content repairs", %{image: image} do
    q = q("q1") |> Map.put("image_ids", [image.id])

    for {extra, kind, code} <- [
          {%{"document_complete" => false, "content_consistent" => false}, "content",
           "content_inconsistent"},
          {%{"document_complete" => false, "visual_paraphrase" => true}, "content",
           "visual_paraphrase"},
          {%{"document_complete" => false, "actual_basis" => "knowledge"}, "content",
           "answer_basis_incompatible"}
        ] do
      Req.Test.stub(__MODULE__, &respond(&1, %{"reviews" => [Map.merge(review("q1"), extra)]}))

      assert {:ok, [], [_], %{"q1" => diagnostic}} =
               OpenAI.audit_response_effort_detailed([q], %{images: [image]})

      assert diagnostic["kind"] == kind
      assert code in diagnostic["issue_codes"]
    end

    Req.Test.stub(
      __MODULE__,
      &respond(&1, %{
        "reviews" => [
          Map.merge(review("q1"), %{"document_complete" => false, "document_focused" => false})
        ]
      })
    )

    assert {:ok, [_], [], %{}} = OpenAI.audit_response_effort_detailed([q], %{images: [image]})
  end

  test "retained questions remain visible evidence without receiving another semantic review", %{
    image: image
  } do
    target = q("q1") |> Map.put("answer_basis", "knowledge")

    retained =
      q("kept")
      |> Map.merge(%{
        "text" => "La membrane délimite la cellule.",
        "answer" => "HIDDEN-RETAINED-ANSWER",
        "expected_elements" => ["HIDDEN-RETAINED-FACT"],
        "image_ids" => [image.id],
        "support_id" => "shared"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      content = hd(Jason.decode!(raw)["input"])["content"]
      prompt = hd(content)["text"]
      assert prompt =~ "CONTEXTE VISIBLE SEULEMENT"
      assert prompt =~ retained["text"]
      assert prompt =~ "Source historique conservée"
      refute prompt =~ "HIDDEN-RETAINED-ANSWER"
      refute prompt =~ "HIDDEN-RETAINED-FACT"
      assert Enum.count(content, &(&1["type"] == "input_image")) == 1

      respond(conn, %{
        "reviews" => [
          Map.merge(review("q1"), %{
            "actual_basis" => "knowledge",
            "answer_exposed" => true,
            "exposure_source_id" => "question:kept",
            "exposure_quote" => retained["text"]
          })
        ]
      })
    end)

    assert {:ok, [], [_], %{"q1" => %{"kind" => "content"}}} =
             OpenAI.audit_response_effort_detailed([target], %{
               retained_questions: [retained],
               images: [image],
               supports: [
                 %{"id" => "shared", "text" => "Source historique conservée", "image_ids" => []}
               ]
             })
  end

  test "exposure-only checks preserve prior semantics and require visible proof" do
    kept =
      q("kept")
      |> Map.merge(%{
        "answer_basis" => "knowledge",
        "response_effort" => "short",
        "verified_response_effort" => "short",
        "verified_answer_basis" => "knowledge"
      })

    context = q("context") |> Map.put("text", "La membrane délimite la cellule.")

    for {source, expected_count} <- [{"question:unknown", 1}, {"question:context", 0}] do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        prompt =
          Jason.decode!(raw)["input"]
          |> hd()
          |> Map.fetch!("content")
          |> hd()
          |> Map.fetch!("text")

        assert prompt =~ "UNIQUEMENT pour une nouvelle exposition"
        assert prompt =~ Jason.encode!(kept["answer"])
        assert prompt =~ "Ne considère pas answer/rubric comme visibles"

        respond(conn, %{
          "reviews" => [],
          "exposure_checks" => [
            %{
              "plan_id" => "kept",
              "answer_exposed" => true,
              "exposure_source_id" => source,
              "exposure_quote" => context["text"]
            }
          ]
        })
      end)

      assert {:ok, accepted, errors, diagnostics} =
               OpenAI.audit_response_effort_detailed([], %{
                 exposure_only_questions: [kept],
                 retained_questions: [context]
               })

      assert length(accepted) == expected_count

      if expected_count == 1 do
        assert accepted == [kept]
        assert errors == []
        assert diagnostics == %{}
      else
        assert [%{} = diagnostic] = Map.values(diagnostics)
        assert diagnostic["issue_codes"] == ["answer_exposed"]
        assert length(errors) == 1
      end
    end
  end

  test "exposure checks cannot silently omit a requested question" do
    Req.Test.stub(__MODULE__, &respond(&1, %{"reviews" => [], "exposure_checks" => []}))

    assert {:error, :invalid_effort_review} =
             OpenAI.audit_response_effort_detailed([], %{exposure_only_questions: [q("kept")]})
  end

  defp q(id),
    do:
      question(id, "reading")
      |> Map.merge(%{
        "plan_id" => id,
        "response_effort" => "direct",
        "answer_basis" => "document",
        "image_ids" => [],
        "support_id" => ""
      })

  defp review(id),
    do: %{
      "plan_id" => id,
      "actual_effort" => "direct",
      "actual_basis" => "document",
      "answer_exposed" => false,
      "exposure_source_id" => "",
      "exposure_quote" => "",
      "content_consistent" => true,
      "document_complete" => true,
      "document_focused" => true,
      "visual_paraphrase" => false,
      "consistent" => true,
      "reason" => "Document à vérifier."
    }

  defp respond(conn, result),
    do:
      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
end
