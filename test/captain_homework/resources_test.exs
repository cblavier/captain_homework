defmodule CaptainHomework.ResourcesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study, Uploads}
  alias CaptainHomework.Resources.{Download, Documents}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    :ok
  end

  test "upload keeps the original and OCR text with unchanged illustration bytes" do
    l = lesson(profile())

    data =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    file = temp(data)
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, file, "exercice.png")
    assert File.read!(Uploads.path(resource.storage_key)) == data
    {:ok, processed} = Resources.process(resource.id)
    assert processed.status == "ready"
    pages = Study.get_lesson!(l.profile_id, l.id).pages
    assert Enum.find(pages, &(&1.kind == "resource")).text != ""
    assert length(pages) == 1
    image = hd(pages)
    assert Uploads.read(image) == data
    assert {:error, :already_processing} = Resources.process(resource.id)
    {:ok, _} = Resources.delete(l.profile_id, resource.id)
    refute File.exists?(Uploads.path(resource.storage_key))
    refute File.exists?(Uploads.path(image.storage_key))
    assert Study.get_lesson!(l.profile_id, l.id).pages == []
  end

  test "failed OCR remains retryable without duplicate pages" do
    l = lesson(profile())

    data =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, temp(data), "exercice.png")
    old_key = Application.get_env(:captain_homework, :openai_api_key)
    on_exit(fn -> Application.put_env(:captain_homework, :openai_api_key, old_key) end)
    Application.put_env(:captain_homework, :openai_api_key, nil)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.AI.OpenAI)
    {:ok, failed} = Resources.process(resource.id)
    assert failed.status == "error"
    assert is_binary(failed.error)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    assert {:ok, _} = Resources.retry(l.profile_id, resource.id)
    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    assert length(Study.get_lesson!(l.profile_id, l.id).pages) == 1
    Resources.delete(l.profile_id, resource.id)
  end

  test "file resources above twenty megabytes preserve the complete original" do
    l = lesson(profile())
    data = [tiny_pdf(), String.duplicate("\n", 21 * 1024 * 1024), "% end of original\n"]
    file = temp(data)
    assert File.stat!(file).size > 20 * 1024 * 1024

    assert {:ok, resource} = Resources.create_upload(l.profile_id, l.id, file, "large.pdf")
    assert resource.content_type == "application/pdf"
    assert File.stat!(Uploads.path(resource.storage_key)).size == File.stat!(file).size
    assert digest(Uploads.path(resource.storage_key)) == digest(file)
    assert resource.status == "processing"
    Resources.delete(l.profile_id, resource.id)
  end

  test "URL resources above twenty megabytes are downloaded without truncation" do
    old = Req.default_options()
    on_exit(fn -> Req.default_options(old) end)
    Req.default_options(Keyword.put(old, :plug, {Req.Test, __MODULE__}))
    chunks = ["%PDF-1.4\n", String.duplicate("x", 21 * 1024 * 1024), "\n%%EOF\n"]

    Req.Test.stub(__MODULE__, fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    assert {:ok, body, "application/pdf", "https://8.8.8.8/large.pdf"} =
             Download.fetch("https://8.8.8.8/large.pdf")

    assert body == IO.iodata_to_binary(chunks)
  end

  test "imports are scoped to their child's lesson and reject unsupported formats" do
    l = lesson(profile())
    assert {:error, _} = Resources.create_upload(l.profile_id, l.id, temp("bad data"), "bad.pdf")

    assert_raise Ecto.NoResultsError, fn ->
      Resources.create_url(profile("Marius").id, l.id, "https://example.com")
    end

    {:ok, resource} = Resources.create_url(l.profile_id, l.id, "https://example.com/doc.pdf")
    assert resource.status == "processing"
    assert resource.storage_key == nil
    assert_raise Ecto.NoResultsError, fn -> Resources.get!(profile("Marius").id, resource.id) end
  end

  test "URL validation rejects local and credential-bearing destinations" do
    for url <- [
          "file:///etc/passwd",
          "http://localhost/a",
          "http://127.0.0.1",
          "http://10.1.2.3",
          "http://169.254.169.254/latest",
          "http://192.168.1.1",
          "http://[::1]",
          "http://[::ffff:127.0.0.1]",
          "https://user:pass@example.com",
          "https://example.com:444"
        ] do
      assert {:error, _} = Download.validate_url(url)
    end

    assert {:ok, _} = Download.validate_url("https://example.com/document.pdf")
    refute Download.public_ip?({100, 64, 0, 1})
    refute Download.public_ip?({172, 31, 1, 1})
    assert Download.public_ip?({8, 8, 8, 8})
  end

  test "a real PDF is rendered, OCRed and its embedded image is extracted" do
    l = lesson(profile())
    file = temp(tiny_pdf())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, file, "fiche.pdf")
    {:ok, processed} = Resources.process(resource.id)
    assert processed.status == "ready", processed.error || "Resource ready"
    pages = Study.get_lesson!(l.profile_id, l.id).pages
    assert [%{text: text}] = Enum.filter(pages, &(&1.kind == "resource"))
    assert text != ""
    assert [%{content_type: "image/png"}] = Enum.filter(pages, &(&1.kind == "illustration"))
    Resources.delete(l.profile_id, resource.id)
  end

  test "PDFs longer than twenty pages preserve each page and illustration origin" do
    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, temp(tiny_pdf(21)), "long.pdf")
    assert {:ok, parts} = Documents.extract(resource)
    assert length(Enum.filter(parts, &(&1.kind == "resource"))) == 21
    illustrations = Enum.filter(parts, &(&1.kind == "illustration"))
    assert length(illustrations) == 21
    assert Enum.any?(illustrations, &String.starts_with?(&1.name, "page-021-figure-"))
    Resources.delete(l.profile_id, resource.id)
  end

  test "PDFs above the bounded page limit fail explicitly" do
    l = lesson(profile())

    {:ok, resource} =
      Resources.create_upload(l.profile_id, l.id, temp(tiny_pdf(101)), "too-long.pdf")

    assert {:error, message} = Documents.extract(resource)
    assert message =~ "100 pages"
    Resources.delete(l.profile_id, resource.id)
  end

  test "PDF lessons use the same pages and directly attached OCR illustrations" do
    l = lesson(profile())

    {:ok, resource} =
      Resources.create_upload(l.profile_id, l.id, temp(tiny_pdf(2)), "lecon.pdf", "lesson")

    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    pages = Study.get_lesson!(l.profile_id, l.id).pages
    originals = Enum.filter(pages, &(&1.kind == "lesson"))
    illustrations = Enum.filter(pages, &(&1.kind == "illustration"))
    assert length(originals) == 2
    assert length(illustrations) == 2
    assert Enum.map(originals, & &1.source_page_number) == [1, 2]

    for image <- illustrations do
      assert image.ocr_status == "complete"
      assert image.extraction_origin == "automatic"
      assert Enum.any?(originals, &(&1.id == image.parent_page_id))
    end

    [first, second] = originals

    assert {:ok, renamed} =
             Study.Pages.rename(l.profile_id, l.id, first.id, %{title: "Les cellules"})

    assert renamed.id == first.id
    assert renamed.filename == first.filename
    assert {:ok, _} = Study.delete_page(second)
    assert Repo.get!(Study.Resource, resource.id)
    assert Repo.get!(Study.Page, first.id).title == "Les cellules"
    Resources.delete(l.profile_id, resource.id)
  end

  test "web import keeps one text page and automatically attaches images with individual OCR" do
    defaults = Req.default_options()
    Req.default_options(Keyword.put(defaults, :plug, {Req.Test, __MODULE__}))
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.default_options(defaults) end)

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/article" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(
            200,
            "<html><head><title>La cellule</title></head><body><nav><img src='/logo.png'></nav><main>Le noyau de la cellule.<img src='/cellule.png'></main></body></html>"
          )

        "/cellule.png" ->
          conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, image)

        _ ->
          flunk("Only content images may be imported")
      end
    end)

    l = lesson(profile())
    {:ok, resource} = Resources.create_url(l.profile_id, l.id, "https://8.8.8.8/article")
    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    pages = Study.get_lesson!(l.profile_id, l.id).pages
    assert [root] = Enum.filter(pages, &(&1.kind == "resource"))
    assert [illustration] = Enum.filter(pages, &(&1.kind == "illustration"))
    assert root.text =~ "Le noyau de la cellule."
    assert illustration.parent_page_id == root.id
    assert illustration.text != ""
    assert illustration.ocr_status == "complete"
    assert Uploads.read(illustration) == image
    assert {:error, _} = Resources.Extraction.source(l.profile_id, l.id, illustration.id)
    assert {:ok, _} = Resources.delete_image(l.profile_id, l.id, illustration.id)
    assert Repo.get!(Study.Page, root.id).text == root.text
    Resources.delete(l.profile_id, resource.id)
  end

  test "retry keeps completed OCR pages instead of reading them again" do
    start_supervised!(%{
      id: CaptainHomework.ResourceRetryCounter,
      start: {Agent, :start_link, [fn -> 0 end, [name: CaptainHomework.ResourceRetryCounter]]}
    })

    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ResourceRetryAI)
    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, temp(tiny_pdf(4)), "retry.pdf")
    {:ok, [part | _]} = Documents.extract(resource)
    key = Ecto.UUID.generate() <> part.ext
    File.write!(Uploads.path(key), part.data)

    {:ok, first} =
      Study.add_page(l, %{
        resource_id: resource.id,
        kind: part.kind,
        filename: part.name,
        storage_key: key,
        content_type: part.type,
        text: "Already recognized",
        status: "ready"
      })

    resource |> Ecto.Changeset.change(status: "error") |> Repo.update!()
    assert {:ok, _} = Resources.retry(l.profile_id, resource.id)
    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    pages = Study.get_lesson!(l.profile_id, l.id).pages
    assert length(pages) == 8
    assert Enum.any?(pages, &(&1.id == first.id and &1.text == "Already recognized"))
    assert length(Enum.filter(pages, &(&1.filename == first.filename))) == 1
    assert Agent.get(CaptainHomework.ResourceRetryCounter, & &1) == 7
    originals = Enum.filter(pages, &(&1.kind == "resource"))

    for image <- Enum.filter(pages, &(&1.kind == "illustration")) do
      assert Enum.any?(
               originals,
               &(&1.id == image.parent_page_id and
                   &1.source_page_number == image.source_page_number)
             )

      assert image.ocr_status == "complete"
    end

    Resources.delete(l.profile_id, resource.id)
  end

  test "PDF links use document metadata as their readable title" do
    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, temp(tiny_pdf()), "view")

    resource =
      resource
      |> Ecto.Changeset.change(source_url: "https://example.com/view")
      |> Repo.update!()

    assert Documents.title(resource) == "History exercises"
    assert {:ok, processed} = Resources.process(resource.id)
    assert processed.title == "History exercises"
    Resources.delete(l.profile_id, resource.id)
  end

  test "HTML extracts readable text without script content" do
    key = Ecto.UUID.generate() <> ".html"
    File.mkdir_p!(Uploads.directory())

    File.write!(
      Uploads.path(key),
      "<html><body><script>evil()</script><main><h1>Exercice</h1><p>Quelle date ?</p></main></body></html>"
    )

    on_exit(fn -> File.rm(Uploads.path(key)) end)

    assert {:ok, [part]} =
             Documents.extract(%{
               content_type: "text/html",
               storage_key: key,
               source_url: "https://example.com"
             })

    assert part.data =~ "Quelle date"
    refute part.data =~ "evil"
  end

  defp temp(data) do
    path = Path.join(System.tmp_dir!(), Ecto.UUID.generate())
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp digest(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp tiny_pdf(count \\ 1) do
    compressed = :zlib.compress(<<255, 0, 0>>)
    contents = "q 40 0 0 40 40 40 cm /Im0 Do Q"
    content_id = count + 3
    image_id = count + 4
    info_id = count + 5

    pages =
      Enum.map(1..count, fn _ ->
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 #{image_id} 0 R >> >> /Contents #{content_id} 0 R >>"
      end)

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{Enum.map_join(3..(count + 2), " ", fn id -> "#{id} 0 R" end)}] /Count #{count} >>"
      ] ++
        pages ++
        [
          "<< /Length #{byte_size(contents)} >>\nstream\n#{contents}\nendstream",
          "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length #{byte_size(compressed)} >>\nstream\n#{compressed}\nendstream",
          "<< /Title (History exercises) >>"
        ]

    {body, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, i}, {body, offsets} ->
        {body <> "#{i} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    xref =
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
        Enum.map_join(offsets, "", &(String.pad_leading(to_string(&1), 10, "0") <> " 00000 n \n"))

    body <>
      xref <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R /Info #{info_id} 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
