defmodule CaptainHomework.ResourceGenerationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study, Exams, Uploads}
  alias CaptainHomework.Exams.Illustrations

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ResourceAI)
    Application.put_env(:captain_homework, :resource_test_pid, self())
    Application.put_env(:captain_homework, :resource_test_image_ids, [])

    on_exit(fn ->
      Application.put_env(:captain_homework, :ai_provider, old)
      Application.delete_env(:captain_homework, :resource_test_pid)
      Application.delete_env(:captain_homework, :resource_test_image_ids)
    end)

    :ok
  end

  test "all example controls guide style without becoming pedagogical sources" do
    p = profile()
    l = lesson(p)
    course = page(l)

    examples =
      for n <- 1..2 do
        {:ok, example} =
          Study.add_page(l, %{
            kind: "example",
            filename: "example-#{n}.png",
            storage_key: "example-#{n}.png",
            content_type: "image/png",
            text: "Contenu pédagogique étranger au cours",
            status: "ready"
          })

        example
      end

    {:ok, result} = Exams.generate(p.id, l.id, 1, "")
    assert_receive {:resource_generation, content_pages, []}
    assert Enum.map(content_pages, & &1.id) == [course.id]
    assert_receive {:style_examples, supplied}
    assert Enum.map(supplied, & &1.id) == Enum.map(examples, & &1.id)
    assert result.generation_examples == Enum.map(examples, & &1.id)
  end

  defp resource(lesson, attrs \\ []) do
    Repo.insert!(
      struct(
        Study.Resource,
        Keyword.merge([lesson_id: lesson.id, filename: "worksheet.pdf", status: "ready"], attrs)
      )
    )
  end

  defp resource_page(lesson, resource, kind, classification \\ "assessment") do
    key = Ecto.UUID.generate() <> ".png"
    File.mkdir_p!(Uploads.directory())
    File.write!(Uploads.path(key), "unchanged original image")
    on_exit(fn -> File.rm(Uploads.path(key)) end)

    {:ok, page} =
      Study.add_page(lesson, %{
        resource_id: resource.id,
        kind: kind,
        document_kind: classification,
        filename: "image.png",
        storage_key: key,
        content_type: "image/png",
        status: "ready",
        text: "Exercice 1 : légende la cellule."
      })

    page
  end

  test "resources supply the course content and exercise priority replaces old retries" do
    p = profile()
    l = lesson(p)
    prior = exam(l)

    Repo.update!(
      Ecto.Changeset.change(prior,
        status: "completed",
        submitted_at: DateTime.utc_now(),
        corrections: %{"q1" => %{"fraction" => 0}}
      )
    )

    r = resource(l)
    pg = resource_page(l, r, "resource")
    {:ok, result} = Exams.generate(p.id, l.id, 1, "", [])
    assert_receive {:resource_generation, pages, []}
    assert Enum.map(pages, & &1.id) == [pg.id]
    assert result.status == "in_progress"
    assert hd(result.questions)["prompt"] == "Exercice du document 1"
  end

  test "question illustrations are byte-identical copies surviving source removal" do
    p = profile()
    l = lesson(p)
    r = resource(l)
    resource_page(l, r, "resource")
    illustration = resource_page(l, r, "illustration")
    Application.put_env(:captain_homework, :resource_test_image_ids, [illustration.id])
    {:ok, result} = Exams.generate(p.id, l.id, 1, "", [])
    on_exit(fn -> Illustrations.delete_exam_images(result) end)
    [asset] = hd(result.questions)["images"]
    refute asset["storage_key"] == illustration.storage_key

    assert File.read!(Uploads.path(asset["storage_key"])) ==
             File.read!(Uploads.path(illustration.storage_key))

    Study.delete_page(illustration)
    assert File.read!(Uploads.path(asset["storage_key"])) == "unchanged original image"
    copied = Illustrations.copy_retry(hd(result.questions))
    on_exit(fn -> Illustrations.delete_exam_images(%{questions: [copied]}) end)
    refute hd(copied["images"])["storage_key"] == asset["storage_key"]
  end

  test "a failed illustration copy cleans up earlier copies in the batch" do
    l = lesson(profile())
    r = resource(l)
    first = resource_page(l, r, "illustration")
    missing = resource_page(l, r, "illustration")
    File.rm!(Uploads.path(missing.storage_key))
    before = Path.wildcard(Path.join(Uploads.directory(), "question-*")) |> Enum.sort()

    questions = [
      Map.put(question("first"), "image_ids", [first.id]),
      Map.put(question("missing"), "image_ids", [missing.id])
    ]

    assert_raise File.CopyError, fn ->
      Illustrations.snapshot_questions(questions, Study.get_lesson!(l.profile_id, l.id))
    end

    assert Enum.sort(Path.wildcard(Path.join(Uploads.directory(), "question-*"))) == before
  end

  test "forged source image ids are rejected and cannot be persisted" do
    p = profile()
    l = lesson(p)
    page(l)
    Application.put_env(:captain_homework, :resource_test_image_ids, [Ecto.UUID.generate()])
    {:ok, result} = Exams.generate(p.id, l.id, 1, "", [])
    assert result.status == "generation_partial"
    assert result.questions == []
    assert Enum.any?(result.generation_errors, &String.contains?(&1, "Illustration inconnue"))
  end

  test "pending or failed resource imports cannot be silently omitted" do
    p = profile()
    l = lesson(p)
    page(l)
    r = resource(l, status: "processing")
    assert {:error, _} = Exams.generate(p.id, l.id, 1, "", [])
    Repo.update!(Ecto.Changeset.change(r, status: "error"))
    assert {:error, _} = Exams.generate(p.id, l.id, 1, "", [])
    refute_receive {:resource_generation, _, _}
  end
end
