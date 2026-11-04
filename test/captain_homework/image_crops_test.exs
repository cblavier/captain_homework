defmodule CaptainHomework.ImageCropsTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.ImageCrops

  setup do
    dir = Path.join(System.tmp_dir!(), "crop-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, executable: System.find_executable("magick") || System.find_executable("convert")}
  end

  defp region(attrs \\ %{}),
    do:
      Map.merge(
        %{"image_id" => "page", "x" => 500, "y" => 0, "width" => 500, "height" => 1000},
        attrs
      )

  test "historical complete images and valid normalized regions are accepted" do
    assert :ok = ImageCrops.validate(["page"], [])
    assert :ok = ImageCrops.validate(["page"], [region()])
    assert :ok = ImageCrops.validate(["page"], [region(%{"x" => 0, "width" => 1000})])
  end

  test "invalid, missing, duplicated and foreign regions are rejected" do
    for regions <- [
          [region(%{"x" => -1})],
          [region(%{"x" => 501})],
          [region(%{"y" => 1})],
          [region(%{"width" => 0})],
          [region(%{"height" => 0})],
          [region(%{"height" => 1.5})],
          [region(%{"image_id" => "foreign"})],
          [region(), region()],
          [%{}],
          [nil],
          nil
        ] do
      assert {:error, _} = ImageCrops.validate(["page"], regions)
    end

    assert {:error, _} = ImageCrops.validate(["page", "other"], [region()])
    assert {:error, _} = ImageCrops.validate([], [region()])
  end

  test "crop retains original pixels and leaves the source untouched", %{
    dir: dir,
    executable: executable
  } do
    source = Path.join(dir, "map.png")

    {_, 0} =
      System.cmd(executable, [
        "-size",
        "100x80",
        "xc:red",
        "-fill",
        "blue",
        "-draw",
        "rectangle 50,0 99,79",
        source
      ])

    original = File.read!(source)

    assert {:ok, cropped} = ImageCrops.render(source, region())
    assert png_dimensions(cropped) == {50, 80}
    assert File.read!(source) == original
    output = Path.join(dir, "cropped.png")
    File.write!(output, cropped)
    {color, 0} = System.cmd(executable, [output, "-format", "%[pixel:p{0,0}]", "info:"])
    assert color in ["srgb(0,0,255)", "srgba(0,0,255,1)"]
  end

  test "coordinates apply after the camera orientation is corrected", %{
    dir: dir,
    executable: executable
  } do
    source = Path.join(dir, "photo.jpg")

    {_, 0} =
      System.cmd(executable, [
        "-size",
        "120x80",
        "xc:red",
        "-fill",
        "blue",
        "-draw",
        "rectangle 60,0 119,79",
        source
      ])

    rotate_camera_orientation(source)

    assert {:ok, cropped} =
             ImageCrops.render(
               source,
               region(%{"x" => 0, "y" => 500, "width" => 1000, "height" => 500})
             )

    assert png_dimensions(cropped) == {80, 60}
    output = Path.join(dir, "oriented.png")
    File.write!(output, cropped)
    {color, 0} = System.cmd(executable, [output, "-format", "%[pixel:p{40,30}]", "info:"])
    [_, red, green, blue] = Regex.run(~r/\((\d+),(\d+),(\d+)/, color)
    assert String.to_integer(red) <= 5
    assert String.to_integer(green) <= 5
    assert String.to_integer(blue) >= 250
  end

  test "a full resolution camera photo can be oriented and cropped within bounded resources", %{
    dir: dir,
    executable: executable
  } do
    source = Path.join(dir, "camera-photo.jpg")
    {_, 0} = System.cmd(executable, ["-size", "4032x3024", "gradient:white-blue", source])
    rotate_camera_orientation(source)
    original = File.read!(source)

    assert {:ok, cropped} =
             ImageCrops.render(
               source,
               region(%{"x" => 60, "y" => 540, "width" => 500, "height" => 170})
             )

    assert png_dimensions(cropped) == {1513, 686}
    assert File.read!(source) == original
  end

  test "an unreadable source or a bad region never falls back to a full page", %{dir: dir} do
    path = Path.join(dir, "broken.png")
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
    assert {:error, _} = ImageCrops.render(path, region())
    assert {:error, _} = ImageCrops.render(path, region(%{"width" => 900}))
    assert {:error, _} = ImageCrops.render(Path.join(dir, "absent.png"), region())
  end

  test "oversized source files are rejected before decoding", %{dir: dir} do
    path = Path.join(dir, "oversized.png")
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :binary])
    {:ok, _} = :file.position(file, 12_000_000)
    :ok = :file.write(file, <<0>>)
    :ok = :file.close(file)
    assert {:error, message} = ImageCrops.render(path, region())
    assert message =~ "12 Mo"
  end

  defp png_dimensions(
         <<137, 80, 78, 71, 13, 10, 26, 10, _length::32, "IHDR", width::32, height::32,
           _::binary>>
       ),
       do: {width, height}

  defp rotate_camera_orientation(source) do
    <<255, 216, jpeg::binary>> = File.read!(source)

    exif =
      <<"Exif", 0, 0, "II", 42::little-16, 8::little-32, 1::little-16, 0x0112::little-16,
        3::little-16, 1::little-32, 6::little-16, 0::16, 0::32>>

    File.write!(
      source,
      <<255, 216, 255, 225, byte_size(exif) + 2::16, exif::binary, jpeg::binary>>
    )
  end
end
