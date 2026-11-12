defmodule CaptainHomework.AI.ProviderError do
  @moduledoc "Bounded provider diagnostics without request bodies or authentication data."

  def details(%Req.Response{} = response) do
    error = if is_map(response.body), do: response.body["error"], else: nil
    error = if is_map(error), do: error, else: %{}

    %{
      "http_status" => response.status,
      "request_id" => response |> Req.Response.get_header("x-request-id") |> List.first(),
      "type" => identifier(error["type"]),
      "code" => identifier(error["code"]),
      "param" => identifier(error["param"])
    }
    |> schema_message(error)
  end

  # Only schema-validation messages are useful here. Other provider messages can
  # echo submitted document text or invalid credentials.
  defp schema_message(details, %{"message" => message} = error) when is_binary(message) do
    if error["code"] == "invalid_json_schema" or
         (error["param"] in ["text.format.schema", "response_format"] and
            String.starts_with?(message, "Invalid schema")) do
      Map.put(details, "message", sanitize(message))
    else
      details
    end
  end

  defp schema_message(details, _), do: details

  defp identifier(value) when is_binary(value) do
    if String.length(value) <= 200 and Regex.match?(~r/\A[a-zA-Z0-9_.\[\]-]+\z/, value),
      do: value
  end

  defp identifier(_), do: nil

  defp sanitize(message) do
    message
    |> String.replace(~r/sk-[A-Za-z0-9_-]+/, "[REDACTED]")
    |> String.replace(~r/Bearer\s+\S+/i, "Bearer [REDACTED]")
    |> String.slice(0, 4000)
  end
end
