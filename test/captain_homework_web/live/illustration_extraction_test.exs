defmodule CaptainHomeworkWeb.IllustrationExtractionTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study, Uploads}
  alias CaptainHomework.Resources.Extraction

  setup do
    keys = [:ai_provider, :uploads_dir, :extraction_test_callback, :extraction_analysis_callback]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    dir = Path.join(System.tmp_dir!(), "extraction-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ExtractionAI)

    Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, _, _ ->
      {:ok, regions()}
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)

      File.rm_rf(dir)
    end)

    executable = System.find_executable("magick") || System.find_executable("convert")

    {_, 0} =
      System.cmd(executable, [
        "-size",
        "100x80",
        "xc:red",
        "-fill",
        "blue",
        "-draw",
        "rectangle 50,0 99,79",
        Uploads.path("source.png")
      ])

    lesson = lesson(profile())

    resource =
      Repo.insert!(%Study.Resource{
        lesson_id: lesson.id,
        filename: "source.png",
        status: "ready",
        content_type: "image/png"
      })

    {:ok, source} =
      Study.add_page(lesson, %{
        kind: "resource",
        resource_id: resource.id,
        filename: "page-1.png",
        storage_key: "source.png",
        content_type: "image/png",
        status: "ready"
      })

    %{lesson: lesson, resource: resource, source: source, dir: dir}
  end

  defp regions,
    do: [
      %{"x" => 0, "y" => 0, "width" => 500, "height" => 1000},
      %{"x" => 500, "y" => 0, "width" => 500, "height" => 1000}
    ]

  test "extraction creates direct children and deletion follows the page hierarchy",
       ctx do
    original = Uploads.read(ctx.source)

    {:ok, crops} =
      Extraction.extract(
        ctx.lesson.profile_id,
        ctx.lesson.id,
        ctx.source.id,
        2,
        "Les deux moitiés"
      )

    assert length(crops) == 2
    assert Uploads.read(ctx.source) == original
    assert Enum.all?(crops, &(&1.text != "" and &1.document_kind == "activity"))

    assert Enum.all?(
             crops,
             &(&1.extracted_from_id == ctx.source.id and &1.resource_id == ctx.resource.id)
           )

    for crop <- crops do
      <<137, 80, 78, 71, 13, 10, 26, 10, _::32, "IHDR", width::32, height::32, _::binary>> =
        Uploads.read(crop)

      assert {width, height} == {50, 80}
    end

    assert {:error, _} = Extraction.source(ctx.lesson.profile_id, ctx.lesson.id, hd(crops).id)
    assert {:ok, _} = Resources.delete_image(ctx.lesson.profile_id, ctx.lesson.id, hd(crops).id)
    assert Repo.get!(Study.Page, ctx.source.id).text == ctx.source.text
    assert Repo.get!(Study.Page, List.last(crops).id)
    assert Repo.get!(Study.Resource, ctx.resource.id).catalogue == nil
    assert {:ok, _} = Study.delete_page(ctx.source)
    assert Study.get_lesson!(ctx.lesson.profile_id, ctx.lesson.id).pages == []
    for crop <- crops, do: refute(File.exists?(Uploads.path(crop.storage_key)))
  end

  test "lesson pages can be extracted and a textless picture has completed OCR", ctx do
    source =
      ctx.source |> Ecto.Changeset.change(kind: "lesson", resource_id: nil) |> Repo.update!()

    Application.put_env(:captain_homework, :extraction_analysis_callback, fn _, _ ->
      {:ok, %{"text" => "", "document_kind" => "other"}}
    end)

    assert {:ok, crops} =
             Extraction.extract(ctx.lesson.profile_id, ctx.lesson.id, source.id, 2, "")

    for crop <- crops do
      assert crop.parent_page_id == source.id
      assert crop.resource_id == nil
      assert crop.ocr_status == "complete"
      assert crop.text == ""
      assert {:error, _} = Extraction.source(ctx.lesson.profile_id, ctx.lesson.id, crop.id)
    end
  end

  test "unreadable crops do not leave ready but unusable illustrations", ctx do
    for result <- [
          {:error, :unavailable},
          :exception
        ] do
      Application.put_env(:captain_homework, :extraction_analysis_callback, fn _, _ ->
        if result == :exception, do: raise("OCR unavailable"), else: result
      end)

      assert {:error, message} =
               Extraction.extract(ctx.lesson.profile_id, ctx.lesson.id, ctx.source.id, 2, "")

      assert message =~ "reconnu"
      assert File.ls!(ctx.dir) == ["source.png"]
      assert length(Study.get_lesson!(ctx.lesson.profile_id, ctx.lesson.id).pages) == 1
    end
  end

  test "bad count, foreign lessons and profiles are rejected before calling the model", ctx do
    Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, _, _ ->
      flunk("Unexpected model call")
    end)

    for {profile_id, lesson_id, count, instructions} <- [
          {ctx.lesson.profile_id, ctx.lesson.id, 0, ""},
          {ctx.lesson.profile_id, ctx.lesson.id, -1, ""},
          {profile("Bob").id, ctx.lesson.id, 2, ""},
          {ctx.lesson.profile_id, Ecto.UUID.generate(), 2, ""},
          {ctx.lesson.profile_id, ctx.lesson.id, 2, String.duplicate("x", 4001)}
        ] do
      assert {:error, _} =
               Extraction.extract(profile_id, lesson_id, ctx.source.id, count, instructions)
    end

    assert File.ls!(ctx.dir) == ["source.png"]
  end

  test "invalid or duplicate regions leave neither partial records nor files", ctx do
    for result <- [
          {:error, "Service indisponible"},
          {:ok, []},
          {:ok, [hd(regions()), hd(regions())]},
          {:ok, [%{}, nil]},
          {:ok, [hd(regions()), %{"x" => 900, "y" => 0, "width" => 500, "height" => 1000}]}
        ] do
      Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, _, _ ->
        result
      end)

      assert {:error, _} =
               Extraction.extract(ctx.lesson.profile_id, ctx.lesson.id, ctx.source.id, 2, "")

      assert File.ls!(ctx.dir) == ["source.png"]

      assert Enum.map(Study.get_lesson!(ctx.lesson.profile_id, ctx.lesson.id).pages, & &1.id) == [
               ctx.source.id
             ]
    end
  end

  test "a resource changed during extraction rolls back all crops", ctx do
    Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, _, _ ->
      ctx.resource |> Ecto.Changeset.change(status: "processing") |> Repo.update!()
      {:ok, regions()}
    end)

    assert {:error, message} =
             Extraction.extract(ctx.lesson.profile_id, ctx.lesson.id, ctx.source.id, 2, "")

    assert message =~ "La ressource a changé"
    assert File.ls!(ctx.dir) == ["source.png"]

    assert Enum.map(Study.get_lesson!(ctx.lesson.profile_id, ctx.lesson.id).pages, & &1.id) == [
             ctx.source.id
           ]
  end

  test "extraction count can exceed ten and reaches the model unchanged", ctx do
    owner = self()

    Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, count, _ ->
      send(owner, {:requested_count, count})
      {:error, "Extraction interrompue pour le test"}
    end)

    {:ok, view, _} =
      live(ctx.conn, "/alice/lecons/#{ctx.lesson.id}?onglet=ressources&page=#{ctx.source.id}")

    view |> element("#extract-page-illustrations") |> render_click()

    for _ <- 1..11 do
      view |> element("#illustration-count-plus:not([disabled])") |> render_click()
    end

    assert has_element?(view, "#illustration-count", "12")
    assert has_element?(view, "#illustration-count-plus:not([disabled])")
    view |> form("#illustration-extraction-form") |> render_submit()
    assert_receive {:requested_count, 12}
    assert has_element?(view, "#extraction-error", "Extraction interrompue pour le test")
  end

  test "modal keeps instructions across count changes, prevents duplicate submissions and refreshes the gallery",
       ctx do
    owner = self()

    Application.put_env(:captain_homework, :extraction_test_callback, fn data,
                                                                         type,
                                                                         count,
                                                                         instructions ->
      send(owner, {:extraction_started, self(), byte_size(data), type, count, instructions})

      receive do
        :finish_extraction -> {:ok, regions()}
      after
        2000 -> {:error, "Test timed out"}
      end
    end)

    {:ok, view, _} =
      live(ctx.conn, "/alice/lecons/#{ctx.lesson.id}?onglet=ressources&page=#{ctx.source.id}")

    view |> element("#extract-page-illustrations") |> render_click()

    assert has_element?(
             view,
             "#extract-illustrations-modal[role=dialog]",
             "Extraire des illustrations"
           )

    assert has_element?(view, "#extraction-source-image[src='/alice/pages/#{ctx.source.id}']")
    assert has_element?(view, "#illustration-count-minus[disabled]")

    view
    |> form("#illustration-extraction-form")
    |> render_change(%{"extraction" => %{"instructions" => "Deux exercices numérotés en orange"}})

    view |> element("#illustration-count-plus") |> render_click()
    assert has_element?(view, "#extraction-instructions", "Deux exercices numérotés en orange")
    view |> form("#illustration-extraction-form") |> render_submit()

    assert_receive {:extraction_started, worker, size, "image/png", 2,
                    "Deux exercices numérotés en orange"}

    assert size > 0
    monitor = Process.monitor(worker)
    assert has_element?(view, "#extract-illustrations[disabled][aria-busy=true] .spinner")

    render_submit(view, "extract_illustrations", %{
      "extraction" => %{"instructions" => "Duplicate"}
    })

    view |> element("#extract-illustrations-modal button[aria-label=Fermer]") |> render_click()
    send(worker, :finish_extraction)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3000
    assert has_element?(view, "#flash-info", "2 illustrations extraites")
    refute has_element?(view, "#extract-illustrations-modal")
    assert has_element?(view, "#preview-original-page")

    crops =
      Study.get_lesson!(ctx.lesson.profile_id, ctx.lesson.id).pages
      |> Enum.filter(& &1.extracted_from_id)

    assert length(crops) == 2
    for crop <- crops, do: assert(has_element?(view, "#resource-image-#{crop.id}"))
    refute_received {:extraction_started, _, _, _, _, "Duplicate"}
  end

  test "failed extraction leaves the modal editable and preserves its values", ctx do
    owner = self()

    Application.put_env(:captain_homework, :extraction_test_callback, fn _, _, _, _ ->
      send(owner, {:worker, self()})

      receive do
        :finish -> {:error, "Précise la zone à extraire."}
      end
    end)

    {:ok, view, _} =
      live(ctx.conn, "/alice/lecons/#{ctx.lesson.id}?onglet=ressources&page=#{ctx.source.id}")

    view |> element("#extract-page-illustrations") |> render_click()

    view
    |> form("#illustration-extraction-form")
    |> render_submit(%{"extraction" => %{"instructions" => "Le schéma de gauche"}})

    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert has_element?(view, "#extraction-error", "Précise la zone")
    assert has_element?(view, "#extraction-instructions", "Le schéma de gauche")
    assert has_element?(view, "#extract-illustrations:not([disabled])")
    assert File.ls!(ctx.dir) == ["source.png"]
  end
end
