defmodule CaptainHomework.ResourcePreflightTest do
  use ExUnit.Case, async: false

  alias CaptainHomework.AI.ResourcePreflight
  alias CaptainHomework.Exams.{BuildError, Illustrations}

  setup do
    previous = Application.fetch_env!(:captain_homework, :uploads_dir)
    directory = Path.join(System.tmp_dir!(), "resource-preflight-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    Application.put_env(:captain_homework, :uploads_dir, directory)

    on_exit(fn ->
      Application.put_env(:captain_homework, :uploads_dir, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "a retained question reserves its image beyond the eight catalogue candidates", %{
    directory: directory
  } do
    images = for n <- 1..9, do: image(directory, "image-#{n}")
    selected = Enum.take(images, 8)
    retained = [%{"image_ids" => ["image-9"], "source_page_ids" => ["course"]}]

    assert {:ok, content, transmitted, []} =
             ResourcePreflight.prepare(
               lesson(images),
               context(selected),
               selected,
               [],
               retained
             )

    assert hd(transmitted).id == "image-9"
    assert Enum.sort(Enum.map(transmitted, & &1.id)) == Enum.sort(Enum.map(images, & &1.id))
    assert Jason.decode!(content)["source_kinds"]["course"] == "lesson"
  end

  test "both question-owned and shared-support images remain mandatory on resume", %{
    directory: directory
  } do
    own = image(directory, "own")
    shared = image(directory, "shared")

    plan = %{
      "questions" => [%{"image_ids" => [own.id], "support_id" => "document"}],
      "supports" => [%{"id" => "document", "image_ids" => [shared.id]}]
    }

    assert {:ok, _, resolved, []} =
             ResourcePreflight.prepare(lesson([own, shared]), context([]), [], [], [], plan)

    assert Enum.map(resolved, & &1.id) == [own.id, shared.id]
    assert Enum.all?(resolved, &is_binary(&1.content_hash))
  end

  test "custom exclusions use the allowed catalogue before its eight-image budget", %{
    directory: directory
  } do
    images = for n <- 1..9, do: image(directory, "image-#{n}")
    selected = Enum.take(images, 8)
    retained = [%{"image_ids" => ["image-9"], "source_page_ids" => ["image-9"]}]

    content =
      selected
      |> context()
      |> Jason.decode!()
      |> Map.put("allowed_image_ids", Enum.map(images, & &1.id))
      |> Map.put("allowed_source_page_ids", ["course" | Enum.map(images, & &1.id)])
      |> Jason.encode!()

    assert {:ok, _, transmitted, []} =
             ResourcePreflight.prepare(lesson(images), content, selected, [], retained, %{},
               custom_instructions?: true
             )

    assert Enum.any?(transmitted, &(&1.id == "image-9"))
  end

  test "an excluded dependency fails instead of bypassing the author's instructions", %{
    directory: directory
  } do
    allowed = image(directory, "allowed")
    excluded = image(directory, "excluded")
    retained = [%{"image_ids" => [excluded.id]}]

    assert {:error, %BuildError{kind: :incompatible_constraints, retryable?: false} = error} =
             ResourcePreflight.prepare(
               lesson([allowed, excluded]),
               context([allowed]),
               [allowed],
               [],
               retained,
               %{},
               custom_instructions?: true
             )

    assert error.details["image_ids"] == [excluded.id]
  end

  test "a missing mandatory image fails before a request can be assembled", %{
    directory: directory
  } do
    missing = image(directory, "missing")
    File.rm!(Path.join(directory, missing.storage_key))

    assert {:error, %BuildError{kind: :missing_asset, stage: :preflight, retryable?: false}} =
             ResourcePreflight.prepare(
               lesson([missing]),
               context([]),
               [],
               [],
               [%{"image_ids" => [missing.id]}]
             )
  end

  test "an immutable retained snapshot remains available after source deletion", %{
    directory: directory
  } do
    snapshot = image(directory, "snapshot")

    retained = [
      %{
        "image_ids" => ["deleted-source"],
        "source_page_ids" => ["course"],
        "images" => [
          %{
            "source_page_id" => "deleted-source",
            "storage_key" => snapshot.storage_key,
            "content_type" => "image/png",
            "crop" => nil
          }
        ]
      }
    ]

    assert {:ok, _, [image], []} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], retained)

    assert image.id == "deleted-source"
    assert image.storage_key == snapshot.storage_key
    assert image.snapshot?
    assert image.snapshot_crop == nil
  end

  test "a cropped snapshot carries its existing crop without claiming original pixels", %{
    directory: directory
  } do
    snapshot = image(directory, "cropped")
    crop = %{"image_id" => "deleted", "x" => 0, "y" => 0, "width" => 500, "height" => 500}

    question = %{
      "image_ids" => ["deleted"],
      "images" => [
        %{
          "source_page_id" => "deleted",
          "storage_key" => snapshot.storage_key,
          "content_type" => "image/png",
          "crop" => crop
        }
      ]
    }

    assert [image] = ResourcePreflight.available_images(lesson([]), [question])
    assert image.snapshot_crop == crop
  end

  test "a cropped snapshot cannot silently replace the missing whole source", %{
    directory: directory
  } do
    snapshot = image(directory, "cropped")
    crop = %{"image_id" => "deleted", "x" => 0, "y" => 0, "width" => 500, "height" => 500}

    retained = %{
      "image_ids" => ["deleted"],
      "image_regions" => [crop],
      "images" => [
        %{
          "source_page_id" => "deleted",
          "storage_key" => snapshot.storage_key,
          "content_type" => "image/png",
          "crop" => crop
        }
      ]
    }

    plan = %{"questions" => [%{"image_ids" => ["deleted"], "image_regions" => []}]}

    assert {:error, %BuildError{kind: :missing_asset}} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], [retained], plan)
  end

  test "missing source provenance is diagnosed independently of existing pixels", %{
    directory: directory
  } do
    image = image(directory, "image")

    assert {:error, %BuildError{kind: :missing_source} = error} =
             ResourcePreflight.prepare(lesson([image]), context([image]), [image], [], [
               %{"image_ids" => [image.id], "source_page_ids" => ["deleted-course"]}
             ])

    assert error.details["source_page_ids"] == ["deleted-course"]
  end

  test "mandatory dependencies never silently disappear when exceeding the request budget", %{
    directory: directory
  } do
    images = for n <- 1..25, do: image(directory, "image-#{n}")
    retained = Enum.map(images, &%{"image_ids" => [&1.id]})

    assert {:error, %BuildError{kind: :resource_budget, retryable?: false}} =
             ResourcePreflight.prepare(lesson(images), context(images), images, [], retained)
  end

  test "optional candidates yield capacity to required images and their catalogue is pruned", %{
    directory: directory
  } do
    images = for n <- 1..25, do: image(directory, "image-#{n}")
    selected = Enum.take(images, 24)
    retained = [%{"image_ids" => ["image-25"]}]

    assert {:ok, content, transmitted, []} =
             ResourcePreflight.prepare(
               lesson(images),
               context(selected),
               selected,
               [],
               retained
             )

    assert length(transmitted) == 24
    assert hd(transmitted).id == "image-25"
    refute Enum.any?(transmitted, &(&1.id == "image-24"))

    refute Enum.any?(
             Jason.decode!(content)["catalogue"],
             &("image-24" in &1["visual_page_ids"])
           )
  end

  test "invalid dependency lists produce a typed error" do
    assert {:error, %BuildError{kind: :invalid_contract}} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], [
               %{"image_ids" => "not-a-list"}
             ])
  end

  test "malformed crop metadata fails as a typed error before resolving files" do
    assert {:error, %BuildError{kind: :invalid_contract}} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], [
               %{"image_ids" => ["missing"], "image_regions" => [42]}
             ])
  end

  test "source byte changes update the dependency fingerprint even with an unchanged key", %{
    directory: directory
  } do
    source = image(directory, "source")
    [before] = ResourcePreflight.available_images(lesson([source]), [])
    File.write!(Path.join(directory, source.storage_key), "changed source bytes")
    [updated] = ResourcePreflight.available_images(lesson([source]), [])

    assert before.storage_key == updated.storage_key
    refute before.content_hash == updated.content_hash
  end

  test "a changed source cannot replace pixels of a retained question during planning", %{
    directory: directory
  } do
    source = image(directory, "source")
    lesson = lesson([source])
    retained = Illustrations.snapshot(%{"image_ids" => [source.id]}, lesson)
    [asset] = retained["images"]
    assert is_binary(asset["source_content_hash"])
    assert is_binary(asset["content_hash"])

    assert {:ok, _, _, []} =
             ResourcePreflight.prepare(lesson, context([source]), [source], [], [retained])

    File.write!(Path.join(directory, source.storage_key), "modified original pixels")

    assert {:error, %BuildError{kind: :stale_dependency, retryable?: false} = error} =
             ResourcePreflight.prepare(lesson, context([source]), [source], [], [retained])

    assert error.details["image_ids"] == [source.id]
  end

  test "changing a snapshot also fails the retained dependency integrity check", %{
    directory: directory
  } do
    source = image(directory, "source")
    lesson = lesson([source])
    retained = Illustrations.snapshot(%{"image_ids" => [source.id]}, lesson)
    [asset] = retained["images"]
    File.write!(Path.join(directory, asset["storage_key"]), "modified snapshot pixels")

    assert {:error, %BuildError{kind: :stale_dependency}} =
             ResourcePreflight.prepare(lesson, context([source]), [source], [], [retained])

    assert {:error, %BuildError{kind: :stale_dependency}} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], [retained])

    copied = Illustrations.copy_retry(retained)

    assert {:error, %BuildError{kind: :stale_dependency}} =
             ResourcePreflight.prepare(lesson([]), context([]), [], [], [copied])
  end

  test "cropped snapshot provenance is verified without interpreting cropped bytes as originals",
       %{
         directory: directory
       } do
    source = image(directory, "source")
    snapshot = image(directory, "cropped")
    crop = %{"image_id" => source.id, "x" => 0, "y" => 0, "width" => 500, "height" => 500}

    hash = fn key ->
      directory
      |> Path.join(key)
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    retained = %{
      "image_ids" => [source.id],
      "image_regions" => [crop],
      "images" => [
        %{
          "source_page_id" => source.id,
          "storage_key" => snapshot.storage_key,
          "content_type" => "image/png",
          "crop" => crop,
          "source_content_hash" => hash.(source.storage_key),
          "content_hash" => hash.(snapshot.storage_key)
        }
      ]
    }

    assert {:ok, _, _, []} =
             ResourcePreflight.prepare(
               lesson([source]),
               context([source]),
               [source],
               [],
               [retained]
             )

    File.write!(Path.join(directory, source.storage_key), "modified original pixels")

    assert {:error, %BuildError{kind: :stale_dependency}} =
             ResourcePreflight.prepare(
               lesson([source]),
               context([source]),
               [source],
               [],
               [retained]
             )
  end

  defp image(directory, id) do
    storage_key = id <> ".png"
    File.write!(Path.join(directory, storage_key), "image bytes for " <> id)

    %{
      id: id,
      kind: "illustration",
      extracted_from_id: "page-original",
      filename: id <> ".png",
      storage_key: storage_key,
      content_type: "image/png",
      resource_id: "resource",
      status: "ready"
    }
  end

  defp lesson(images) do
    %{
      resources: [%{id: "resource", status: "ready"}],
      pages: [%{id: "course", kind: "lesson", resource_id: nil} | images]
    }
  end

  defp context(images) do
    Jason.encode!(%{
      "source_kinds" => %{"course" => "lesson"},
      "catalogue" =>
        Enum.map(images, fn image ->
          %{
            "kind" => "visual",
            "source_page_ids" => [image.id],
            "visual_page_ids" => [image.id]
          }
        end)
    })
  end
end
