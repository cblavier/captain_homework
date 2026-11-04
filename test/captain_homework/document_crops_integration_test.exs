defmodule CaptainHomework.DocumentCropsIntegrationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Repo, Study, Uploads}
  alias CaptainHomework.AI.{OpenAI, VisibleImages}
  alias CaptainHomework.Exams.Illustrations

  setup do
    keys = [:uploads_dir, :openai_api_key, :openai_request_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    dir = Path.join(System.tmp_dir!(), "document-crops-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
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

    lesson = lesson(profile())

    resource =
      Repo.insert!(%Study.Resource{
        lesson_id: lesson.id,
        filename: "documents.png",
        status: "ready"
      })

    executable = System.find_executable("magick") || System.find_executable("convert")

    {_, 0} =
      System.cmd(executable, [
        "-size",
        "200x100",
        "xc:blue",
        "-fill",
        "red",
        "-draw",
        "rectangle 0,50 199,99",
        Uploads.path("documents.png")
      ])

    {:ok, page} =
      Study.add_page(lesson, %{
        resource_id: resource.id,
        kind: "resource",
        status: "ready",
        filename: "documents.png",
        storage_key: "documents.png",
        content_type: "image/png"
      })

    %{lesson: Study.get_lesson!(lesson.profile_id, lesson.id), page: page}
  end

  defp question_with_crop(page, id, y) do
    question(id, "reading")
    |> Map.merge(%{
      "plan_id" => id,
      "prompt" => "Observe le document et relève une information.",
      "text" => "",
      "image_ids" => [page.id],
      "image_regions" => [
        %{"image_id" => page.id, "x" => 0, "y" => y, "width" => 1000, "height" => 500}
      ],
      "source_page_ids" => [page.id],
      "response_effort" => "direct",
      "answer_basis" => "document"
    })
  end

  test "new questions audit and save the uploaded image unchanged", ctx do
    draft = question_with_crop(ctx.page, "q1", 500)

    assert {:ok, decoded} =
             CaptainHomework.AI.QuestionContract.decode(
               %{"questions" => %{"q1" => draft}, "supports" => []},
               ["q1"]
             )

    [q] = decoded["questions"]
    assert {:ok, [_], [], [visible]} = VisibleImages.prepare([q], [], [ctx.page])
    original = File.read!(Uploads.path(ctx.page.storage_key))
    assert visible.data == original
    [asset] = Illustrations.snapshot(q, ctx.lesson)["images"]
    assert File.read!(Uploads.path(asset["storage_key"])) == original
    assert asset["crop"] == nil
  end

  test "separate extracts of one document are audited and saved as the same cropped pixels",
       ctx do
    questions = [
      question_with_crop(ctx.page, "map", 0),
      question_with_crop(ctx.page, "historical-text", 500)
    ]

    original = Uploads.read(ctx.page)
    for q <- questions, do: assert(AI.question_errors(q) == [])
    assert {:ok, visible, [], images} = VisibleImages.prepare(questions, [], [ctx.page])
    assert length(images) == 2
    assert Enum.uniq(Enum.map(visible, & &1["image_ids"])) |> length() == 2
    refute Enum.any?(visible, &Map.has_key?(&1, "image_regions"))
    assert Enum.all?(images, &(dimensions(&1.data) == {200, 50}))

    for {q, visible_q} <- Enum.zip(questions, visible) do
      snapshot = Illustrations.snapshot(q, ctx.lesson)
      [asset] = snapshot["images"]
      image = Enum.find(images, &(&1.id in visible_q["image_ids"]))
      assert File.read!(Uploads.path(asset["storage_key"])) == image.data
      assert asset["source_page_id"] == ctx.page.id
      retry = Illustrations.copy_retry(snapshot)
      [retry_asset] = retry["images"]
      assert retry_asset["id"] != asset["id"]
      assert File.read!(Uploads.path(retry_asset["storage_key"])) == image.data
    end

    assert Uploads.read(ctx.page) == original
  end

  test "review request contains cropped pixels while accepted questions keep their source references",
       ctx do
    q = question_with_crop(ctx.page, "map", 0)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(body)["input"] |> hd() |> Map.fetch!("content")
      [image] = Enum.filter(content, &(&1["type"] == "input_image"))
      [_, encoded] = String.split(image["image_url"], ",", parts: 2)
      assert dimensions(Base.decode64!(encoded)) == {200, 50}
      assert hd(content)["text"] =~ "-crop-"

      result = %{
        "reviews" => [
          %{
            "plan_id" => "map",
            "actual_effort" => "direct",
            "actual_basis" => "document",
            "answer_exposed" => false,
            "exposure_source_id" => "",
            "exposure_quote" => "",
            "consistent" => true,
            "reason" => "Document exploitable."
          }
        ]
      }

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, [accepted], []} = OpenAI.audit_response_effort([q], %{images: [ctx.page]})
    assert accepted["image_ids"] == [ctx.page.id]
    assert accepted["image_regions"] == q["image_regions"]
  end

  test "an invalid crop is rejected before copying or sending the full page", ctx do
    q = question_with_crop(ctx.page, "map", 700)
    assert {[], [_]} = Illustrations.validate([q], ctx.lesson)
    assert {:error, _} = VisibleImages.prepare([q], [], [ctx.page])
    refute File.exists?(Uploads.path("question-map.png"))
  end

  defp dimensions(
         <<137, 80, 78, 71, 13, 10, 26, 10, _::32, "IHDR", width::32, height::32, _::binary>>
       ),
       do: {width, height}
end
