defmodule CaptainHomework.Exams.BuildError do
  @moduledoc "A typed failure at an exercise construction boundary, without an implicit AI retry."

  @enforce_keys [:kind, :stage, :message]
  defstruct [:kind, :stage, :message, details: %{}, retryable?: false]

  @doc "Creates an error; retries are disabled unless explicitly requested."
  def new(kind, stage, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      stage: stage,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      retryable?: Keyword.get(opts, :retryable?, false)
    }
  end

  @doc "Returns a JSON-compatible diagnostic without converting external strings to atoms."
  def to_map(%__MODULE__{} = error) do
    %{
      "kind" => to_string(error.kind),
      "stage" => to_string(error.stage),
      "message" => error.message,
      "details" => error.details,
      "retryable" => error.retryable?
    }
  end
end
