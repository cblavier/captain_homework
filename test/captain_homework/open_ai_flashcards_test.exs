defmodule CaptainHomework.OpenAIFlashcardsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, Repo, Study}

  setup do
    keys = [:openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:captain_homework, :ai_provider, AI.OpenAI)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)

    :ok
  end

  test "real generation adapter sends only course pages, enforces one point and audits quick recall" do
    p = profile()
    l = lesson(p)
    first = page(l)

    second =
      page(l)
      |> Ecto.Changeset.change(text: "Le noyau contient l'information génétique.")
      |> Repo.update!()

    page(l)
    |> Ecto.Changeset.change(kind: "example", text: "EXAMPLE_SHOULD_NOT_BE_SENT")
    |> Repo.update!()

    resource =
      Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "Resource", status: "ready"})

    page(l)
    |> Ecto.Changeset.change(
      kind: "resource",
      resource_id: resource.id,
      text: "RESOURCE_SHOULD_NOT_BE_SENT"
    )
    |> Repo.update!()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [%{"content" => [%{"type" => "input_text", "text" => prompt}]}] = request["input"]
      refute String.contains?(prompt, "EXAMPLE_SHOULD_NOT_BE_SENT")
      refute String.contains?(prompt, "RESOURCE_SHOULD_NOT_BE_SENT")
      schema = request["text"]["format"]["schema"]["properties"]

      result =
        if schema["questions"] do
          assert String.contains?(prompt, first.text)
          assert String.contains?(prompt, second.text)
          properties = schema["questions"]["items"]["properties"]
          assert properties["points"]["enum"] == [1]
          assert properties["type"]["enum"] == ["definition"]

          %{
            "questions" => [
              question("q", "definition")
              |> Map.merge(%{"points" => 1, "source_page_ids" => [first.id]})
            ]
          }
        else
          assert schema["reviews"]

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "knowledge",
                  "answer_exposed" => false,
                  "exposure_source_id" => "",
                  "exposure_quote" => "",
                  "consistent" => true,
                  "reason" => "Rappel rapide du cours."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 1, "",
               format: "flashcard",
               question_types: ["definition", "long"]
             )

    assert generated.status == "in_progress"

    assert [
             %{
               "points" => 1,
               "verified_response_effort" => "direct",
               "verified_answer_basis" => "knowledge"
             }
           ] = generated.questions

    assert generated.generation_plan == nil
  end
end
