defmodule CaptainHomework.Resources.Download do
  @moduledoc false
  alias CaptainHomework.Resources.GoogleDrive
  @transfer_timeout 10 * 60 * 1000

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and uri.port in [80, 443] and byte_size(url) <= 4000 do
      case :inet.parse_address(String.to_charlist(uri.host)) do
        {:ok, ip} ->
          if public_ip?(ip), do: {:ok, uri}, else: invalid_url()

        _ ->
          if String.downcase(uri.host) in ["localhost", "localhost.localdomain"],
            do: invalid_url(),
            else: {:ok, uri}
      end
    else
      invalid_url()
    end
  rescue
    _ -> invalid_url()
  end

  def validate_url(_), do: invalid_url()

  def fetch(url) do
    with {:ok, uri} <- validate_url(url) do
      case GoogleDrive.prepare(uri) do
        :not_drive -> fetch(url, 0)
        {:ok, download_url, id} -> fetch_drive(download_url, URI.to_string(uri), id, 0)
        {:error, _} = error -> error
      end
    end
  end

  defp fetch_drive(url, original, id, confirmations) do
    with {:ok, body, type, _} <- fetch(url, 0) do
      cond do
        String.starts_with?(body, "%PDF-") ->
          {:ok, body, "application/pdf", original}

        match?({:ok, _, _}, CaptainHomework.Uploads.image_type(body)) ->
          {:ok, image_type, _} = CaptainHomework.Uploads.image_type(body)
          {:ok, body, image_type, original}

        type in ["text/html", "application/xhtml+xml"] and confirmations == 0 ->
          with {:ok, confirmation_url} <- GoogleDrive.confirmation(body, id) do
            fetch_drive(confirmation_url, original, id, confirmations + 1)
          end

        type in ["text/html", "application/xhtml+xml"] ->
          GoogleDrive.access_error()

        true ->
          {:error, "Le fichier Google Drive doit être un PDF ou une image JPEG, PNG ou WebP."}
      end
    end
  end

  defp fetch(_, hops) when hops > 4, do: {:error, "Trop de redirections pour cette URL."}

  defp fetch(url, hops) do
    with {:ok, uri} <- validate_url(url),
         {:ok, ip} <- resolve(uri.host) do
      # Pin the validated address, preserving the HTTP host and TLS certificate hostname.
      pinned = %{uri | host: ip |> :inet.ntoa() |> to_string(), fragment: nil}
      headers = [{"host", uri.host}, {"accept-encoding", "identity"}]
      deadline = System.monotonic_time(:millisecond) + @transfer_timeout

      response =
        Req.get(URI.to_string(pinned),
          headers: headers,
          redirect: false,
          retry: false,
          decode_body: false,
          compressed: false,
          receive_timeout: 30_000,
          connect_options: [hostname: uri.host, timeout: 5_000, protocols: [:http1]],
          into: fn {:data, chunk}, {request, response} ->
            if System.monotonic_time(:millisecond) > deadline do
              {:halt, {request, %{response | body: :download_timeout}}}
            else
              chunks = if is_list(response.body), do: response.body, else: []
              {:cont, {request, %{response | body: [chunk | chunks]}}}
            end
          end
        )

      case response do
        {:ok, %{body: :download_timeout}} ->
          {:error,
           "Le téléchargement du document a pris trop de temps. Réessaie ou importe directement le fichier."}

        {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
          case Req.Response.get_header(response, "location") do
            [location | _] -> fetch(URI.merge(uri, location) |> URI.to_string(), hops + 1)
            _ -> {:error, "La redirection du document est invalide."}
          end

        {:ok, %{status: 200, body: chunks} = response}
        when is_list(chunks) or is_binary(chunks) ->
          body = chunks |> List.wrap() |> Enum.reverse() |> IO.iodata_to_binary()

          type =
            response
            |> Req.Response.get_header("content-type")
            |> List.first()
            |> to_string()
            |> String.split(";")
            |> hd()

          {:ok, body, type, URI.to_string(uri)}

        {:ok, %{status: status}} ->
          {:error,
           "Le site a répondu avec le code #{status}. Vérifie que le document est public."}

        _ ->
          {:error, "Le document est inaccessible. Vérifie son URL et réessaie."}
      end
    end
  rescue
    _ -> {:error, "Le document est inaccessible. Vérifie son URL et réessaie."}
  end

  defp resolve(host) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(String.to_charlist(host), family, 5_000) do
          {:ok, ips} -> ips
          _ -> []
        end
      end)

    if addresses != [] and Enum.all?(addresses, &public_ip?/1),
      do: {:ok, hd(addresses)},
      else: invalid_url()
  end

  def public_ip?({a, b, c, _}) do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or (a == 192 and b in [0, 168]) or
           (a == 198 and b in [18, 19, 51]) or (a == 203 and b == 0 and c == 113))
  end

  # Only global unicast IPv6, excluding mapped IPv4, documentation and transition ranges.
  def public_ip?({a, b, _, _, _, _, _, _}),
    do:
      a in 0x2000..0x3FFF and a != 0x2002 and
        not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and not (a == 0x3FFF and b == 0)

  def public_ip?(_), do: false
  defp invalid_url, do: {:error, "Utilise une URL publique HTTP ou HTTPS, sans identifiants."}
end
