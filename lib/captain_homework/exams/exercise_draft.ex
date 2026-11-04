defmodule CaptainHomework.Exams.ExerciseDraft do
  @moduledoc "An untrusted instruction proposal, bound to exactly one immutable exercise contract."
  alias CaptainHomework.Exams.{BuildError, ExerciseSpec, ValidatedExercise}

  @enforce_keys [:spec_id, :spec_hash, :prompt]
  defstruct [:spec_id, :spec_hash, :prompt]

  @doc "Accepts only spec_id, spec_hash and prompt; extra fields are rejected, never silently dropped."
  def new(%ExerciseSpec{} = spec, payload) when is_map(payload) and not is_struct(payload) do
    cond do
      Enum.sort(Map.keys(payload)) != ~w(prompt spec_hash spec_id) ->
        failure(:invalid_draft, "Seule la consigne peut être proposée dans un brouillon.")

      payload["spec_id"] != spec.id or payload["spec_hash"] != spec.hash ->
        failure(:contract_mismatch, "Le brouillon ne correspond pas au contrat demandé.")

      not is_binary(payload["prompt"]) or String.trim(payload["prompt"]) == "" ->
        failure(:invalid_draft, "La consigne du brouillon est vide ou invalide.")

      true ->
        {:ok, %__MODULE__{spec_id: spec.id, spec_hash: spec.hash, prompt: payload["prompt"]}}
    end
  end

  def new(_, _),
    do: failure(:invalid_draft, "Un objet de brouillon lié à son contrat est requis.")

  @doc "Returns the strict, JSON-compatible drafting envelope."
  def to_map(%__MODULE__{} = draft),
    do: %{"spec_id" => draft.spec_id, "spec_hash" => draft.spec_hash, "prompt" => draft.prompt}

  @doc "Loads a draft with the same strict checks as a newly received proposal."
  def from_map(payload, spec), do: new(spec, payload)

  @doc "Checks the contract and draft, then constructs an exercise awaiting pedagogical audit."
  def build(spec, draft, context), do: ValidatedExercise.build(spec, draft, context)

  defp failure(kind, message), do: {:error, BuildError.new(kind, :draft, message)}
end
