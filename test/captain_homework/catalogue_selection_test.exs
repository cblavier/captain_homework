defmodule CaptainHomework.CatalogueSelectionTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Catalogues, Repo, Resources, Study, Uploads}
  alias CaptainHomework.AI.OpenAI

  setup do
    keys = [:uploads_dir, :openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    dir = Path.join(System.tmp_dir!(), "catalogue-selection-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
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

  defp stub(entries) do
    caller = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(caller, :catalogue_requested)

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{
            "content" => [
              %{"type" => "output_text", "text" => Jason.encode!(%{"entries" => entries})}
            ]
          }
        ]
      })
    end)
  end

  defp entry(page, attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "exercise",
        "title" => "La cellule",
        "content" => "Nomme la membrane.",
        "keywords" => ["cellule"],
        "usable" => true,
        "source_page_ids" => [page.id],
        "visual_page_ids" => []
      },
      attrs
    )
  end

  test "reordering an isolated course page reuses its semantic analysis" do
    page = page(lesson(profile()))
    stub([entry(page, %{"kind" => "knowledge"})])
    assert {:ok, _} = Catalogues.prepare_page(page)
    assert_receive :catalogue_requested

    legacy =
      {1, OpenAI, Application.get_env(:captain_homework, :openai_model),
       [
         Map.take(page, [
           :id,
           :text,
           :position,
           :filename,
           :storage_key,
           :document_kind,
           :content_type
         ])
       ]}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Repo.get!(Study.Page, page.id)
    |> Ecto.Changeset.change(catalogue_hash: legacy)
    |> Repo.update!()

    assert {:ok, _} = Catalogues.prepare_page(page)
    refute_receive :catalogue_requested
    refute Repo.get!(Study.Page, page.id).catalogue_hash == legacy
    moved = page |> Ecto.Changeset.change(position: 42) |> Repo.update!()
    assert {:ok, _} = Catalogues.prepare_page(moved)
    refute_receive :catalogue_requested
  end

  test "infeasible visual candidates do not crowd out usable text exercises" do
    lesson = lesson(profile())

    {:ok, resource} =
      Resources.create_url(lesson.profile_id, lesson.id, "https://example.com/course.pdf")

    resource |> Ecto.Changeset.change(status: "ready") |> Repo.update!()

    pages =
      for n <- 1..2 do
        {:ok, page} =
          Study.add_page(lesson, %{
            resource_id: resource.id,
            kind: "resource",
            status: "ready",
            filename: "page-#{n}.png",
            storage_key: "p#{n}.png",
            content_type: "image/png",
            text: "Texte reconnu"
          })

        page
      end

    [missing, usable] = pages
    File.write!(Uploads.path(usable.storage_key), "available image")

    blocked =
      for n <- 1..30,
          do: entry(missing, %{"title" => "Illustration #{n}", "visual_page_ids" => [missing.id]})

    fallback = entry(usable)
    stub(blocked ++ [fallback])
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)
    assert {:ok, content, [], []} = Catalogues.context(lesson, pages, [], 1, "", [])
    assert Jason.decode!(content)["catalogue"] == [fallback]
  end

  test "reserves a feasible visual before course content exhausts the catalogue budget" do
    lesson = lesson(profile())
    course_page = page(lesson)

    large_course =
      entry(course_page, %{
        "kind" => "knowledge",
        "title" => "La cellule",
        "content" => String.duplicate("A", 8_000)
      })

    small_course =
      entry(course_page, %{
        "kind" => "knowledge",
        "title" => "Notion complémentaire",
        "keywords" => [],
        "content" => "La membrane délimite la cellule."
      })

    stub([large_course, small_course])
    assert {:ok, _} = Catalogues.prepare_page(course_page)

    {:ok, resource} =
      Resources.create_url(lesson.profile_id, lesson.id, "https://example.com/activities.pdf")

    resource = resource |> Ecto.Changeset.change(status: "ready") |> Repo.update!()

    {:ok, visual_page} =
      Study.add_page(lesson, %{
        resource_id: resource.id,
        kind: "resource",
        status: "ready",
        filename: "page-1.png",
        storage_key: "visual.png",
        content_type: "image/png",
        text: "Une cellule à observer."
      })

    File.write!(Uploads.path(visual_page.storage_key), "available visual")

    visual =
      entry(visual_page, %{
        "content" => String.duplicate("E", 7_000),
        "visual_page_ids" => [visual_page.id]
      })

    supporting_facts =
      for n <- 1..4 do
        entry(visual_page, %{
          "kind" => "knowledge",
          "title" => "Fait #{n}",
          "content" => String.duplicate(to_string(n), 7_000)
        })
      end

    stub([visual | supporting_facts])
    assert {:ok, _} = Catalogues.prepare_resource(resource)
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)

    assert {:ok, content, [^visual_page], []} =
             Catalogues.context(lesson, [course_page, visual_page], [], 5, "", [])

    selected = Jason.decode!(content)["catalogue"]
    assert visual in selected
    assert small_course in selected
    refute large_course in selected
  end
end
