defmodule CaptainHomework.Resources.Audio do
  @moduledoc "Extracts temporary audio and retains only its transcript."
  alias CaptainHomework.{AI, ProcessingProgress, Repo, Uploads}
  alias CaptainHomework.Resources.{Download, MediaCommand}

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be www.youtu.be youtube-nocookie.com www.youtube-nocookie.com)
  @max_bytes 512 * 1024 * 1024

  def media?(resource),
    do: resource.content_type in ["audio/mpeg", "video/mp4", "application/x-youtube"]

  def type(<<"ID3", _::binary>>), do: {:ok, "audio/mpeg", ".mp3"}

  def type(<<255, second, _::binary>>) when Bitwise.band(second, 0xE6) == 0xE2,
    do: {:ok, "audio/mpeg", ".mp3"}

  def type(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>)
      when brand in ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "M4A ", "dash"],
      do: {:ok, "video/mp4", ".mp4"}

  def type(_), do: :not_media

  def youtube_url(uri) do
    if String.downcase(uri.host || "") in @youtube_hosts do
      id =
        case {String.downcase(uri.host), String.split(uri.path || "", "/", trim: true)} do
          {host, [id]} when host in ["youtu.be", "www.youtu.be"] -> id
          {_, ["watch"]} -> URI.decode_query(uri.query || "")["v"]
          {_, [kind, id]} when kind in ["shorts", "embed", "live"] -> id
          _ -> nil
        end

      if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id),
        do: {:ok, "https://www.youtube.com/watch?v=" <> id, id},
        else:
          {:error, "Colle le lien d’une vidéo YouTube, pas celui d’une chaîne ou d’une playlist."}
    else
      :not_youtube
    end
  end

  def transcribe(resource) do
    dir = Path.join(System.tmp_dir!(), "homework-audio-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    try do
      with {:ok, input} <- source(resource, dir),
           :ok <- validate_media(input),
           :ok <- ProcessingProgress.update(resource, 20, "Extraction de l’audio"),
           {:ok, _} <-
             MediaCommand.run("ffmpeg", [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-y",
               "-format_whitelist",
               "mp3,mov,matroska,webm,ogg,wav,aac",
               "-protocol_whitelist",
               "file,pipe",
               "-i",
               input,
               "-map",
               "0:a:0",
               "-vn",
               "-sn",
               "-dn",
               "-map_metadata",
               "-1",
               "-ac",
               "1",
               "-ar",
               "16000",
               "-c:a",
               "libmp3lame",
               "-b:a",
               "64k",
               "-f",
               "segment",
               "-segment_time",
               "600",
               "-reset_timestamps",
               "1",
               Path.join(dir, "audio-%03d.mp3")
             ]),
           {:ok, text} <-
             transcribe_chunks(
               resource,
               Path.wildcard(Path.join(dir, "audio-*.mp3")) |> Enum.sort()
             ),
           {:ok, resource} <- save_transcript(resource, text) do
        {:ok, resource}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp source(%{content_type: "application/x-youtube", source_url: url} = resource, dir) do
    with {:ok, uri} <- Download.validate_url(url),
         {:ok, canonical, _} <- youtube_url(uri),
         :ok <- ProcessingProgress.update(resource, 10, "Chargement de l’audio YouTube"),
         {:ok, _} <-
           MediaCommand.run("yt-dlp", [
             "--ignore-config",
             "--no-plugin-dirs",
             "--no-playlist",
             "--no-progress",
             "--no-cache-dir",
             "--js-runtimes",
             "node",
             "--socket-timeout",
             "30",
             "--retries",
             "2",
             "--fragment-retries",
             "2",
             "--match-filters",
             "!is_live & duration <= 7200",
             "--max-filesize",
             to_string(@max_bytes),
             "-f",
             "bestaudio[protocol=https]/bestaudio[protocol=http]",
             "-o",
             Path.join(dir, "source.%(ext)s"),
             "--",
             canonical
           ]),
         [path] <- Path.wildcard(Path.join(dir, "source.*")) do
      {:ok, path}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "Cette vidéo YouTube est indisponible, en direct ou dépasse les limites (2 heures, 512 Mo)."}
    end
  end

  defp source(resource, _dir), do: {:ok, Uploads.path(resource.storage_key)}

  defp validate_media(path) do
    with {:ok, %{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, output} <-
           MediaCommand.run(
             "ffprobe",
             [
               "-v",
               "error",
               "-format_whitelist",
               "mp3,mov,matroska,webm,ogg,wav,aac",
               "-protocol_whitelist",
               "file,pipe",
               "-show_entries",
               "format=duration",
               "-of",
               "default=noprint_wrappers=1:nokey=1",
               path
             ],
             30_000
           ),
         {duration, _} when duration > 0 and duration <= 7200 <- Float.parse(String.trim(output)) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Le média doit être lisible et ne pas dépasser 2 heures ou 512 Mo."}
    end
  end

  defp transcribe_chunks(_resource, []),
    do: {:error, "Ce média ne contient pas d’audio exploitable."}

  defp transcribe_chunks(resource, paths) do
    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {path, index}, {:ok, texts} ->
      ProcessingProgress.update(
        resource,
        30 + round(50 * (index - 1) / length(paths)),
        "Transcription audio — #{index}/#{length(paths)}"
      )

      with {:ok, data} <- File.read(path),
           {:ok, text} when is_binary(text) <- AI.transcribe(data, "audio/mpeg") do
        {:cont, {:ok, [String.trim(text) | texts]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, "La transcription audio a échoué. Réessaie."}}
      end
    end)
    |> case do
      {:ok, texts} ->
        text = texts |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

        if text == "",
          do: {:error, "Aucune parole n’a été reconnue dans ce média."},
          else: {:ok, text}

      error ->
        error
    end
  end

  defp save_transcript(resource, text) do
    key = Ecto.UUID.generate() <> ".txt"
    File.mkdir_p!(Uploads.directory())
    File.write!(Uploads.path(key), text)
    filename = Path.rootname(resource.filename) <> ".txt"

    case resource
         |> Ecto.Changeset.change(
           storage_key: key,
           content_type: "text/plain",
           filename: filename
         )
         |> Repo.update() do
      {:ok, updated} ->
        if resource.storage_key, do: File.rm(Uploads.path(resource.storage_key))
        {:ok, updated}

      error ->
        File.rm(Uploads.path(key))
        error
    end
  end
end
