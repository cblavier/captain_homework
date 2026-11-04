defmodule CaptainHomework.AI.Trace do
  @moduledoc "Records request duration and usage without recording document contents or secrets."
  require Logger
  alias CaptainHomework.AI.Call
  alias CaptainHomework.Repo

  def with_exam(exam_id, fun), do: with_context(:exam_id, exam_id, fun)
  def with_stage(stage, fun), do: with_context(:stage, stage, fun)
  def with_progress(callback, fun), do: with_context(:progress, callback, fun)

  # Worker tasks inherit attribution, but never the coordinator's persistence callback.
  def context, do: %{exam_id: Process.get({__MODULE__, :exam_id})}
  def with_context(%{exam_id: id}, fun), do: with_exam(id, fun)

  def request(body, fun) do
    started = System.monotonic_time(:millisecond)

    try do
      if callback = Process.get({__MODULE__, :progress}) do
        properties =
          get_in(field(body, :text) || %{}, [
            :format,
            :schema,
            "properties",
            "questions",
            "properties"
          ])

        count = if is_map(properties), do: map_size(properties), else: nil
        callback.(Process.get({__MODULE__, :stage}) || stage(body), count)
      end

      result = fun.()
      record(body, result, started)
      result
    rescue
      error ->
        record(body, :exception, started)
        reraise error, __STACKTRACE__
    catch
      kind, value ->
        record(body, :exception, started)
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  defp with_context(key, value, fun) do
    key = {__MODULE__, key}
    previous = Process.get(key)
    Process.put(key, value)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  defp record(body, result, started) do
    attrs = %{
      exam_id: Process.get({__MODULE__, :exam_id}),
      stage: Process.get({__MODULE__, :stage}) || stage(body),
      model: field(body, :model),
      duration_ms: max(System.monotonic_time(:millisecond) - started, 0),
      image_count: image_count(body),
      max_output_tokens: field(body, :max_output_tokens)
    }

    attrs = Map.merge(attrs, result_metadata(result))
    Repo.insert!(struct(Call, attrs))

    Logger.info(
      "ai_call stage=#{attrs.stage} exam_id=#{attrs.exam_id} status=#{attrs.status} " <>
        "duration_ms=#{attrs.duration_ms} input_tokens=#{attrs[:input_tokens]} " <>
        "output_tokens=#{attrs[:output_tokens]} cached_tokens=#{attrs[:cached_tokens]} " <>
        "images=#{attrs.image_count} request_id=#{attrs[:request_id]}"
    )
  rescue
    _ -> Logger.warning("ai_call_metrics_unavailable")
  catch
    _, _ -> Logger.warning("ai_call_metrics_unavailable")
  end

  defp result_metadata({:ok, %Req.Response{} = response}) do
    body = if is_map(response.body), do: response.body, else: %{}
    usage = body["usage"] || %{}

    %{
      status: response_status(response.status, body),
      http_status: response.status,
      request_id: response |> Req.Response.get_header("x-request-id") |> List.first(),
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cached_tokens: get_in(usage, ["input_tokens_details", "cached_tokens"]),
      reasoning_tokens: get_in(usage, ["output_tokens_details", "reasoning_tokens"]),
      total_tokens: usage["total_tokens"],
      incomplete_reason: incomplete_reason(body)
    }
  end

  defp result_metadata({:error, _}), do: %{status: "transport_error"}
  defp result_metadata(:exception), do: %{status: "exception"}
  defp result_metadata(_), do: %{status: "unknown"}

  defp response_status(status, _) when status not in 200..299, do: "http_error"

  defp response_status(_, %{"status" => status})
       when status in ~w(completed incomplete failed cancelled queued in_progress),
       do: status

  defp response_status(_, _), do: "completed"

  defp incomplete_reason(body) do
    reason = get_in(body, ["incomplete_details", "reason"])

    if reason in ~w(max_output_tokens max_messages content_filter steered), do: reason
  end

  defp image_count(body) do
    (field(body, :input) || [])
    |> Enum.flat_map(&(field(&1, :content) || []))
    |> Enum.count(&(field(&1, :type) == "input_image"))
  end

  defp stage(body) do
    properties = Enum.reduce([:text, :format, :schema, :properties], body, &field(&2, &1)) || %{}

    cond do
      Map.has_key?(properties, "reviews") -> "audit"
      Map.has_key?(properties, "supports") -> "planning"
      Map.has_key?(properties, "questions") -> "repair"
      Map.has_key?(properties, "grades") -> "grading"
      Map.has_key?(properties, "entries") -> "catalogue"
      Map.has_key?(properties, "format") -> "question_type"
      Map.has_key?(properties, "document_kind") -> "ocr_analysis"
      Map.has_key?(properties, "text") -> "ocr"
      true -> "analysis"
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
end
