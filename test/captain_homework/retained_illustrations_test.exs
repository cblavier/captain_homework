defmodule CaptainHomework.RetainedIllustrationsTest do
  use ExUnit.Case, async: false

  alias CaptainHomework.AI.VisibleImages
  alias CaptainHomework.Exams.Illustrations

  setup do
    previous = Application.fetch_env!(:captain_homework, :uploads_dir)
    directory = Path.join(System.tmp_dir!(), "retained-images-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    Application.put_env(:captain_homework, :uploads_dir, directory)

    on_exit(fn ->
      Application.put_env(:captain_homework, :uploads_dir, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "retained snapshots are accepted explicitly without allowing forged new sources", %{
    directory: directory
  } do
    question = question(directory)
    lesson = %{resources: [], pages: []}

    assert {[], [_]} = Illustrations.validate([question], lesson)
    assert {[^question], []} = Illustrations.validate([question], lesson, allow_snapshots: true)
  end

  test "missing retained snapshot files are rejected even when a source still exists", %{
    directory: directory
  } do
    question = question(directory)
    source = source(directory, "original.png", "current original bytes")
    lesson = %{resources: [%{id: "resource", status: "ready"}], pages: [source]}
    File.rm!(Path.join(directory, "snapshot.png"))

    assert {[], [_]} = Illustrations.validate([question], lesson, allow_snapshots: true)
  end

  test "snapshotting an already cropped retained question copies its exact pixels", %{
    directory: directory
  } do
    question = question(directory, crop())
    copied = Illustrations.snapshot(question, %{resources: [], pages: []})
    [asset] = copied["images"]

    refute asset["storage_key"] == "snapshot.png"
    assert asset["crop"] == crop()
    assert File.read!(Path.join(directory, asset["storage_key"])) == "immutable snapshot pixels"
  end

  test "the reviewer sees a retained crop as stored without applying its crop again", %{
    directory: directory
  } do
    question = question(directory, crop())

    assert {:ok, [visible], [], [image]} = VisibleImages.prepare([question], [], [])
    assert visible["image_ids"] == [image.id]
    assert image.data == "immutable snapshot pixels"
    assert image.snapshot_crop == crop()
    refute Map.has_key?(visible, "image_regions")
  end

  test "retained and current pixels with the same source id stay distinct in an audit", %{
    directory: directory
  } do
    retained = question(directory)
    original = source(directory, "original.png", "modified original pixels")
    fresh = %{"image_ids" => ["source"], "image_regions" => []}

    assert {:ok, [visible_retained, visible_fresh], [], images} =
             VisibleImages.prepare([retained, fresh], [], [original])

    refute visible_retained["image_ids"] == visible_fresh["image_ids"]
    assert length(images) == 2
    by_id = Map.new(images, &{&1.id, &1.data})
    assert by_id[hd(visible_retained["image_ids"])] == "immutable snapshot pixels"
    assert by_id[hd(visible_fresh["image_ids"])] == "modified original pixels"
  end

  defp question(directory, crop \\ nil) do
    File.write!(Path.join(directory, "snapshot.png"), "immutable snapshot pixels")

    %{
      "image_ids" => ["source"],
      "image_regions" => if(crop, do: [crop], else: []),
      "images" => [
        %{
          "source_page_id" => "source",
          "storage_key" => "snapshot.png",
          "content_type" => "image/png",
          "crop" => crop
        }
      ]
    }
  end

  defp source(directory, key, bytes) do
    File.write!(Path.join(directory, key), bytes)

    %{
      id: "source",
      resource_id: "resource",
      storage_key: key,
      content_type: "image/png",
      filename: "original.png",
      kind: "illustration"
    }
  end

  defp crop,
    do: %{"image_id" => "source", "x" => 0, "y" => 0, "width" => 500, "height" => 500}
end
