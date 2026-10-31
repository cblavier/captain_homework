defmodule CaptainHomework.ResourcesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Resources, Study, Uploads}
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
    image = Enum.find(pages, &(&1.kind == "illustration"))
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
    assert length(Study.get_lesson!(l.profile_id, l.id).pages) == 2
    Resources.delete(l.profile_id, resource.id)
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

  defp tiny_pdf do
    compressed = :zlib.compress(<<255, 0, 0>>)
    contents = "q 40 0 0 40 40 40 cm /Im0 Do Q"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length #{byte_size(contents)} >>\nstream\n#{contents}\nendstream",
      "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length #{byte_size(compressed)} >>\nstream\n#{compressed}\nendstream"
    ]

    {body, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, i}, {body, offsets} ->
        {body <> "#{i} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    xref =
      "xref\n0 6\n0000000000 65535 f \n" <>
        Enum.map_join(offsets, "", &(String.pad_leading(to_string(&1), 10, "0") <> " 00000 n \n"))

    body <> xref <> "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
