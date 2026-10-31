defmodule CaptainHomework.Resources.Documents do
  @moduledoc false
  alias CaptainHomework.{Uploads, Resources.Download}
  @max_pages 20
  @max_images 40
  @max_extracted_bytes 80 * 1024 * 1024

  def type(data, hint \\ "")
  def type(<<"%PDF-", _::binary>>, _), do: {:ok, "application/pdf", ".pdf"}

  def type(data, hint) do
    case Uploads.image_type(data) do
      {:ok, type, ext} ->
        {:ok, type, ext}

      _ ->
        if hint == "text/html" and String.valid?(data),
          do: {:ok, "text/html", ".html"},
          else: {:error, "Format non pris en charge : PDF, JPEG, PNG, WebP ou page web attendu."}
    end
  end

  def extract(%{content_type: "application/pdf"} = resource), do: pdf(resource)
  def extract(%{content_type: "text/html"} = resource), do: html(resource)

  def extract(resource) do
    data = Uploads.read(resource)

    with {:ok, type, ext} <- type(data) do
      part = %{data: data, type: type, ext: ext, kind: "resource", name: resource.filename}
      {:ok, [part, %{part | kind: "illustration"}]}
    end
  end

  defp pdf(resource) do
    dir = Path.join(System.tmp_dir!(), "homework-pdf-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    try do
      input = Uploads.path(resource.storage_key)

      with {:ok, info} <- command("pdfinfo", [input]),
           {:ok, count} <- page_count(info),
           {:ok, image_info} <- command("pdfimages", ["-list", input]),
           :ok <- check_image_budget(image_info),
           {:ok, _} <-
             command("pdftoppm", [
               "-png",
               "-scale-to",
               "1800",
               "-f",
               "1",
               "-l",
               to_string(count),
               input,
               Path.join(dir, "page")
             ]),
           {:ok, _} <-
             command("pdfimages", [
               "-png",
               "-j",
               "-f",
               "1",
               "-l",
               to_string(count),
               input,
               Path.join(dir, "figure")
             ]) do
        pages = Path.wildcard(Path.join(dir, "page-*.png")) |> Enum.sort()
        images = Path.wildcard(Path.join(dir, "figure-*")) |> Enum.sort()

        if length(images) > @max_images do
          {:error,
           "Le PDF contient plus de #{@max_images} images. Importe un document plus court."}
        else
          with {:ok, page_parts} <- read_parts(pages, "resource"),
               {:ok, illustrations} <- read_parts(images, "illustration") do
            illustrations =
              if illustrations == [],
                do: Enum.map(page_parts, &%{&1 | kind: "illustration"}),
                else: illustrations

            all = page_parts ++ illustrations

            if Enum.reduce(all, 0, &(byte_size(&1.data) + &2)) <= @max_extracted_bytes,
              do: {:ok, all},
              else:
                {:error, "Les images extraites dépassent 80 Mo. Importe un document plus court."}
          end
        end
      end
    after
      File.rm_rf(dir)
    end
  end

  defp check_image_budget(info) do
    dimensions =
      Regex.scan(~r/^\s*\d+\s+\d+\s+\S+\s+(\d+)\s+(\d+)\s/m, info, capture: :all_but_first)

    pixels =
      Enum.reduce(dimensions, 0, fn [width, height], total ->
        total + String.to_integer(width) * String.to_integer(height)
      end)

    if length(dimensions) <= @max_images and pixels <= 40_000_000,
      do: :ok,
      else:
        {:error,
         "Les images du PDF sont trop nombreuses ou trop grandes. Importe un document plus court."}
  end

  defp page_count(info) do
    case Regex.run(~r/^Pages:\s+(\d+)/m, info) do
      [_, count] ->
        count = String.to_integer(count)

        if count in 1..@max_pages,
          do: {:ok, count},
          else: {:error, "Le PDF doit contenir entre 1 et #{@max_pages} pages."}

      _ ->
        {:error, "Ce PDF est illisible ou protégé par un mot de passe."}
    end
  end

  defp read_parts(paths, kind) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, parts} ->
      existing_bytes = Enum.reduce(parts, 0, &(byte_size(&1.data) + &2))

      with {:ok, %{size: size}}
           when size <= 12_000_000 and existing_bytes + size <= @max_extracted_bytes <-
             File.stat(path),
           {:ok, data} <- File.read(path),
           {:ok, type, ext} <- type(data) do
        {:cont,
         {:ok,
          parts ++ [%{data: data, type: type, ext: ext, kind: kind, name: Path.basename(path)}]}}
      else
        _ ->
          {:halt,
           {:error, "Une image du PDF ne peut pas être extraite (12 Mo maximum par image)."}}
      end
    end)
  end

  defp html(resource) do
    document = resource |> Uploads.read() |> LazyHTML.from_document()
    tree = document |> LazyHTML.to_tree() |> readable_tree()

    text =
      tree
      |> LazyHTML.from_tree()
      |> LazyHTML.text(separator: "\n")
      |> String.trim()
      |> String.slice(0, 100_000)

    image_urls = document |> LazyHTML.query("img") |> LazyHTML.attribute("src") |> Enum.uniq()

    if length(image_urls) > @max_images do
      {:error,
       "La page web contient plus de #{@max_images} images. Choisis un document plus court."}
    else
      base = %{
        data: text,
        type: "text/plain",
        ext: ".txt",
        kind: "resource",
        name: "Texte de la page web"
      }

      Enum.reduce_while(image_urls, {:ok, [base]}, fn source, {:ok, parts} ->
        url = URI.merge(resource.source_url, source) |> URI.to_string()

        existing_bytes = Enum.reduce(parts, 0, &(byte_size(&1.data) + &2))

        with {:ok, data, _, _} <- Download.fetch(url),
             true <-
               byte_size(data) <= 12_000_000 and
                 existing_bytes + 2 * byte_size(data) <= @max_extracted_bytes,
             {:ok, type, ext} <- Uploads.image_type(data) do
          name = source |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename()
          part = %{data: data, type: type, ext: ext, kind: "resource", name: name}
          {:cont, {:ok, parts ++ [part, %{part | kind: "illustration"}]}}
        else
          _ ->
            {:halt,
             {:error,
              "Une image de la page web est inaccessible ou dans un format non pris en charge. Importe le document en PDF."}}
        end
      end)
    end
  end

  defp readable_tree(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &readable_tree/1)

  defp readable_tree({tag, _, _})
       when tag in ["script", "style", "nav", "header", "footer", "noscript"], do: []

  defp readable_tree({tag, attrs, children}), do: [{tag, attrs, readable_tree(children)}]
  defp readable_tree(text) when is_binary(text), do: [text]
  defp readable_tree(_), do: []

  defp command(name, args) do
    executable = System.find_executable(name)

    if executable do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      collect(port, "", System.monotonic_time(:millisecond) + 60_000)
    else
      {:error, "L’import PDF nécessite Poppler (pdfinfo, pdftoppm et pdfimages) sur le serveur."}
    end
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, String.slice(output <> data, 0, 200_000), deadline)
      {^port, {:exit_status, 0}} -> {:ok, output}
      {^port, {:exit_status, _}} -> {:error, "Le PDF est illisible, protégé ou trop complexe."}
    after
      remaining ->
        Port.close(port)
        {:error, "Le traitement du PDF a dépassé une minute. Importe un document plus court."}
    end
  end
end
