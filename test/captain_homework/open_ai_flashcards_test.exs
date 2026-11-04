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

  test "chronological flashcards use numbered events and a permutation as their expected answer" do
    {:ok, _} = CaptainHomework.QuestionDefinitions.seed!()

    type =
      Enum.find(CaptainHomework.QuestionDefinitions.list(), &(&1.response_kind == "ordering"))

    l = lesson(profile(), "histoire-geo")
    source = page(l)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      schema = request["text"]["format"]["schema"]["properties"]
      [%{"content" => [%{"text" => prompt}]}] = request["input"]

      result =
        if schema["questions"] do
          assert schema["questions"]["items"]["properties"]["type"]["enum"] == ["ordering"]
          assert prompt =~ "l’interface les numérote de 1 à N"

          %{
            "questions" => [
              question("q1", "ordering")
              |> Map.merge(%{
                "prompt" => "Classe ces événements du plus ancien au plus récent.",
                "options" => ["Écriture", "Maîtrise du feu", "Agriculture"],
                "answer" => "2, 3, 1",
                "points" => 1,
                "source_page_ids" => [source.id]
              })
            ]
          }
        else
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
                  "reason" => "Classement de faits appris."
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
             Exams.generate(l.profile_id, l.id, 1, "",
               format: "flashcard",
               question_types: [type.id]
             )

    assert generated.status == "in_progress"
    assert [%{"type" => "ordering", "answer" => "2, 3, 1"}] = generated.questions
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
               question_types: question_type_ids(["definition", "long"])
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

  test "hidden numbered vocabulary is rejected and repaired while autonomous cards are kept" do
    p = profile()
    l = lesson(p)

    source =
      page(l)
      |> Ecto.Changeset.change(text: "Halloween vocabulary\n1. bat\n2. candle\n3. ghost")
      |> Repo.update!()

    translation =
      question("translation", "definition")
      |> Map.merge(%{
        "prompt" => "Traduis « bougie » en anglais.",
        "answer" => "candle",
        "rubric" => "1 point pour candle.",
        "source_page_ids" => [source.id]
      })

    missing_list =
      question("missing-list", "mcq")
      |> Map.merge(%{
        "prompt" => "QCM : Quel mot correspond au numéro 1 dans la liste ?",
        "options" => ["bat", "ghost", "cat"],
        "answer" => "bat",
        "rubric" => "1 point pour bat.",
        "source_page_ids" => [source.id]
      })

    repaired = Map.put(missing_list, "prompt", "Quel mot anglais signifie chauve-souris ?")
    drafts = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [%{"content" => [%{"type" => "input_text", "text" => prompt}]}] = request["input"]
      schema = request["text"]["format"]["schema"]["properties"]

      result =
        if schema["questions"] do
          assert prompt =~ "Les pages de cours et leur OCR ne sont pas affichés"

          case Agent.get_and_update(drafts, &{&1, &1 + 1}) do
            0 ->
              %{"questions" => [translation, missing_list]}

            1 ->
              assert prompt =~ "Crée exactement 1 flashcards"
              assert prompt =~ "Diagnostics"
              saved = Repo.one!(Study.Exam)
              assert [kept] = saved.questions
              assert kept["prompt"] == translation["prompt"]
              send(owner, {:kept_card, kept["id"]})
              %{"questions" => [repaired]}
          end
        else
          assert prompt =~ "Une source OCR qui contient ces éléments ne les rend pas"

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          # Even an auditor approving everything never sees the unusable draft.
          refute Enum.any?(questions, &(&1["prompt"] == missing_list["prompt"]))

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
             Exams.generate(p.id, l.id, 2, "",
               format: "flashcard",
               question_types: question_type_ids(["definition", "mcq"])
             )

    assert generated.status == "in_progress"
    assert generated.generation_errors == []

    assert Enum.map(generated.questions, & &1["prompt"]) ==
             [translation["prompt"], repaired["prompt"]]

    assert_receive {:kept_card, kept_id}
    assert hd(generated.questions)["id"] == kept_id
    assert Agent.get(drafts, & &1) == 2
  end
end
