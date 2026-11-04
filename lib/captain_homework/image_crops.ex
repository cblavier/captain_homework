defmodule CaptainHomework.ImageCrops do
  @moduledoc "Crops original resource images using coordinates on the oriented image."
  alias CaptainHomework.Uploads

  @max_bytes 12_000_000
  @max_pixels 40_000_000
  @timeout_ms 15_000
  # Orientation can require simultaneous source and destination pixel caches.
  # Q16-HDRI builds need more than 256 MiB even for a standard 12 MP camera photo.
  @disk_cache_limit "2GiB"
  @invalid "Le cadrage doit identifier chaque image une seule fois et rester dans ses limites (coordonnées de 0 à 1000)."

  # Missing regions on historical questions preserve their complete image.
  def validate(image_ids, []) when is_list(image_ids), do: :ok

  def validate(image_ids, regions) when is_list(image_ids) and is_list(regions) do
    ids = Enum.map(regions, &if(is_map(&1), do: &1["image_id"]))

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(ids) == length(Enum.uniq(ids)) and
         MapSet.new(ids) == MapSet.new(image_ids) and
         Enum.all?(regions, &valid_region?/1) do
      :ok
    else
      {:error, @invalid}
    end
  end

  def validate(_, _), do: {:error, @invalid}

  def render(path, region) do
    if valid_region?(region) do
      with {:ok, %{size: size, type: :regular}} when size <= @max_bytes <- File.stat(path),
           {:ok, data} <- File.read(path),
           {:ok, type, _} <- Uploads.image_type(data),
           {:ok, executable} <- executable(),
           input = coder(type) <> ":" <> Path.expand(path) <> "[0]",
           {:ok, dimensions} <-
             command(executable, ["-ping", input, "-format", "%w %h %[orientation]", "info:"]),
           {:ok, width, height} <- dimensions(dimensions) do
        crop(executable, input, region, width, height)
      else
        {:error, message} when is_binary(message) -> {:error, message}
        _ -> {:error, "L’image à recadrer est indisponible ou dépasse 12 Mo."}
      end
    else
      {:error, @invalid}
    end
  end

  defp valid_region?(%{"x" => x, "y" => y, "width" => width, "height" => height}) do
    Enum.all?([x, y, width, height], &is_integer/1) and
      x >= 0 and y >= 0 and width > 0 and height > 0 and
      x + width <= 1000 and y + height <= 1000
  end

  defp valid_region?(_), do: false

  defp executable do
    case System.find_executable("magick") || System.find_executable("convert") do
      nil -> {:error, "Le recadrage nécessite ImageMagick sur le serveur."}
      executable -> {:ok, executable}
    end
  end

  defp coder("image/jpeg"), do: "jpeg"
  defp coder("image/png"), do: "png"
  defp coder("image/webp"), do: "webp"

  defp dimensions(output) do
    case String.split(String.trim(output)) do
      [width, height, orientation] ->
        with {width, ""} when width > 0 <- Integer.parse(width),
             {height, ""} when height > 0 <- Integer.parse(height),
             true <- width * height <= @max_pixels do
          if orientation in ["LeftTop", "RightTop", "RightBottom", "LeftBottom"],
            do: {:ok, height, width},
            else: {:ok, width, height}
        else
          _ ->
            {:error, "L’image à recadrer dépasse 40 mégapixels ou ses dimensions sont invalides."}
        end

      _ ->
        {:error, "Les dimensions de l’image à recadrer sont illisibles."}
    end
  end

  defp crop(executable, input, region, width, height) do
    left = div(region["x"] * width, 1000)
    top = div(region["y"] * height, 1000)
    right = div((region["x"] + region["width"]) * width + 999, 1000)
    bottom = div((region["y"] + region["height"]) * height + 999, 1000)
    geometry = "#{right - left}x#{bottom - top}+#{left}+#{top}"
    directory = Path.join(System.tmp_dir!(), "homework-crop-#{Ecto.UUID.generate()}")
    output = Path.join(directory, "crop.png")
    File.mkdir_p!(directory)

    try do
      with {:ok, _} <-
             command(executable, [
               input,
               "-auto-orient",
               "-crop",
               geometry,
               "+repage",
               "-strip",
               "png:" <> output
             ]),
           {:ok, %{size: size}} when size <= @max_bytes <- File.stat(output),
           {:ok, data} <- File.read(output) do
        {:ok, data}
      else
        {:error, message} when is_binary(message) -> {:error, message}
        _ -> {:error, "L’image recadrée est indisponible ou dépasse 12 Mo."}
      end
    after
      File.rm_rf(directory)
    end
  end

  defp command(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-limit",
          "memory",
          "128MiB",
          "-limit",
          "map",
          "256MiB",
          "-limit",
          "disk",
          @disk_cache_limit,
          "-limit",
          "thread",
          "1",
          "-limit",
          "time",
          "15" | args
        ]
      ])

    collect(port, "", System.monotonic_time(:millisecond) + @timeout_ms)
  rescue
    _ -> {:error, "Impossible de lancer le recadrage de l’image."}
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(
          port,
          binary_part(output <> data, 0, min(byte_size(output) + byte_size(data), 8192)),
          deadline
        )

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error, "L’image ne peut pas être recadrée. Vérifie son format et ses dimensions."}
    after
      remaining ->
        Port.close(port)
        {:error, "Le recadrage de l’image a dépassé quinze secondes."}
    end
  end
end
