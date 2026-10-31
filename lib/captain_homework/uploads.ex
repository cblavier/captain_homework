defmodule CaptainHomework.Uploads do
  @max_bytes 12 * 1024 * 1024
  def directory, do: Application.fetch_env!(:captain_homework, :uploads_dir)
  def path(key), do: Path.join(directory(), Path.basename(key))

  def store(temp, filename) do
    with {:ok, %{size: size}} when size <= @max_bytes <- File.stat(temp),
         {:ok, data} <- File.read(temp),
         {:ok, type, ext} <- image_type(data) do
      File.mkdir_p!(directory())
      key = Ecto.UUID.generate() <> ext
      File.write!(path(key), data)
      {:ok, %{filename: Path.basename(filename), storage_key: key, content_type: type, text: ""}}
    else
      _ -> {:error, "Choisis une image JPEG, PNG ou WebP de moins de 12 Mo."}
    end
  end

  def image_type(<<255, 216, 255, _::binary>>), do: {:ok, "image/jpeg", ".jpg"}
  def image_type(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: {:ok, "image/png", ".png"}

  def image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>),
    do: {:ok, "image/webp", ".webp"}

  def image_type(_), do: {:error, :invalid_image}
  def read(page), do: File.read!(path(page.storage_key))
end
