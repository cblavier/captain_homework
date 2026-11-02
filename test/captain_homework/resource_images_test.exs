defmodule CaptainHomework.ResourceImagesTest do
  use ExUnit.Case, async: false
  alias CaptainHomework.AI.ResourceImages

  setup do
    old = Application.fetch_env!(:captain_homework, :uploads_dir)
    dir = Path.join(System.tmp_dir!(), "resource-images-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)

    on_exit(fn ->
      Application.put_env(:captain_homework, :uploads_dir, old)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp image(dir, id, kind, filename, opts \\ []) do
    key = "#{id}.png"
    path = Path.join(dir, key)
    size = Keyword.get(opts, :size, 100)
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :binary])

    if size > 0 do
      :ok = :file.write(file, binary_part(id, 0, min(byte_size(id), size)))
      {:ok, _} = :file.position(file, size - 1)
      :ok = :file.write(file, <<0>>)
    end

    :ok = :file.close(file)

    %{
      id: id,
      kind: kind,
      filename: filename,
      resource_id: Keyword.get(opts, :resource, "resource-a"),
      storage_key: key
    }
  end

  test "small documents retain every source and example", %{dir: dir} do
    page = image(dir, "p1", "resource", "page-01.png")
    figure = image(dir, "f1", "illustration", "page-001-figure-042.jpg")
    example = image(dir, "ex", "example", "example.png")
    refute ResourceImages.selection_required?([page, figure], [example])

    assert {:ok, [^page, ^figure], [^example]} =
             ResourceImages.select([page, figure], [example], :all)
  end

  test "selected pages retain requested order and only associated figures", %{dir: dir} do
    one = image(dir, "p1", "resource", "page-01.png")
    two = image(dir, "p2", "resource", "page-02.png")
    figure_one = image(dir, "f1", "illustration", "page-001-figure-042.jpg")
    figure_two = image(dir, "f2", "illustration", "page-002-figure-043.jpg")

    foreign =
      image(dir, "foreign", "illustration", "page-002-figure-001.jpg", resource: "resource-b")

    unselected = image(dir, "f3", "illustration", "page-003-figure-002.jpg")
    sources = [one, two, figure_one, figure_two, foreign, unselected]

    assert {:ok, [^two, ^one, ^figure_two, ^figure_one], []} =
             ResourceImages.select(sources, [], ["p2", "p1", "p2"])

    assert {:error, _} = ResourceImages.select(sources, [], ["foreign"])
    assert {:error, _} = ResourceImages.select(sources, [], ["unknown"])
  end

  test "HTML images with colliding basenames associate only with their matching content", %{
    dir: dir
  } do
    page = image(dir, "p", "resource", "figure.png")
    figure = image(dir, "f", "illustration", "figure.png")
    File.cp!(Path.join(dir, page.storage_key), Path.join(dir, figure.storage_key))
    second_page = image(dir, "p2", "resource", "figure.png")
    second_figure = image(dir, "f2", "illustration", "figure.png")
    File.cp!(Path.join(dir, second_page.storage_key), Path.join(dir, second_figure.storage_key))
    foreign = image(dir, "other", "illustration", "figure.png", resource: "resource-b")
    File.cp!(Path.join(dir, page.storage_key), Path.join(dir, foreign.storage_key))
    unrelated = image(dir, "unrelated", "illustration", "another-figure.png")
    sources = [page, figure, second_page, second_figure, foreign, unrelated]

    assert {:ok, [^page, ^figure], []} = ResourceImages.select(sources, [], ["p"])
    assert {:ok, [^second_page, ^second_figure], []} = ResourceImages.select(sources, [], ["p2"])

    resembling_pdf =
      Enum.map(
        [page, figure, second_page, second_figure, foreign],
        &%{
          &1
          | filename: "page-001.png"
        }
      )

    assert {:ok, selected, []} = ResourceImages.select(resembling_pdf, [], ["p"])
    assert Enum.map(selected, & &1.id) == ["p", "f"]
  end

  test "page and example count is mandatory while overflow figures are omitted", %{dir: dir} do
    page = image(dir, "p", "resource", "page-01.png")
    figures = for n <- 1..30, do: image(dir, "f#{n}", "illustration", "page-001-figure-#{n}.png")
    examples = for n <- 1..2, do: image(dir, "e#{n}", "example", "example.png")
    assert ResourceImages.selection_required?([page | figures], examples)
    assert {:error, _} = ResourceImages.select([page | figures], examples, :all)
    assert {:ok, selected, ^examples} = ResourceImages.select([page | figures], examples, ["p"])
    assert hd(selected) == page
    assert length(selected) == 22
    too_many = for n <- 1..25, do: image(dir, "p#{n}", "resource", "page-#{n}.png")
    assert {:error, _} = ResourceImages.select(too_many, [], Enum.map(too_many, & &1.id))
    assert {:error, _} = ResourceImages.select([], too_many, [])
  end

  test "byte budgets include examples", %{dir: dir} do
    page = image(dir, "p", "resource", "page-01.png", size: 12 * 1024 * 1024)
    figure = image(dir, "f", "illustration", "page-001-figure-001.png", size: 1)
    example = image(dir, "e", "example", "ex.png", size: 12 * 1024 * 1024)
    assert ResourceImages.selection_required?([page, figure], [example])
    assert {:ok, [^page], [^example]} = ResourceImages.select([page, figure], [example], ["p"])
    larger = image(dir, "larger", "example", "large.png", size: 12 * 1024 * 1024 + 1)
    assert {:error, _} = ResourceImages.select([page], [larger], ["p"])
    assert {:error, _} = ResourceImages.select([], [example, larger], [])
  end

  test "identical pixels consume one budget slot, prefer illustration and preserve every id", %{
    dir: dir
  } do
    page = image(dir, "p", "resource", "page-01.png", size: 13 * 1024 * 1024)
    figure = image(dir, "f", "illustration", "page-001-figure-001.png")
    File.cp!(Path.join(dir, page.storage_key), Path.join(dir, figure.storage_key))
    assert {:ok, [^page, ^figure], []} = ResourceImages.select([page, figure], [], ["p"])

    assert [%{image: ^figure, ids: ["p", "f"], data: data}] =
             ResourceImages.transmission_groups([page, figure])

    assert data == File.read!(Path.join(dir, figure.storage_key))
  end

  test "missing unselected files and optional figures do not block usable pages", %{dir: dir} do
    page = image(dir, "p", "resource", "page-01.png")
    unused = image(dir, "unused", "resource", "page-02.png")
    optional = image(dir, "optional", "illustration", "page-001-figure-001.png")
    for item <- [unused, optional], do: File.rm!(Path.join(dir, item.storage_key))
    assert {:ok, [^page], []} = ResourceImages.select([page, unused, optional], [], ["p"])
    assert {:ok, [], []} = ResourceImages.select([unused], [], [])
    assert {:error, _} = ResourceImages.select([unused], [], ["unused"])
  end

  test "missing files are reported rather than silently skipped", %{dir: dir} do
    page = image(dir, "p", "resource", "page-01.png")
    File.rm!(Path.join(dir, page.storage_key))
    assert ResourceImages.selection_required?([page], [])
    assert {:error, message} = ResourceImages.select([page], [], :all)
    assert message =~ "indisponible"
    assert_raise File.Error, fn -> ResourceImages.transmission_groups([page]) end
  end
end
