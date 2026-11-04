defmodule CaptainHomework.Exams.ValidatedExercise do
  @moduledoc """
  An exercise whose construction satisfies its immutable contract.

  This is structural validation only. `pedagogical_audit` remains `:pending`:
  neither JSON decoding nor matching a hash proves that an instruction is clear,
  that its answer is true or that the whole exam avoids answer leakage.
  """
  alias CaptainHomework.AI
  alias CaptainHomework.Exams.{BuildError, ExerciseDraft, ExerciseSpec}

  @enforce_keys [:spec, :draft]
  defstruct [:spec, :draft, structural_validation: :valid, pedagogical_audit: :pending]

  @doc "Builds only from a current contract and a draft that proposes its instruction alone."
  def build(%ExerciseSpec{} = spec, %ExerciseDraft{} = draft, context) do
    with :ok <- ExerciseSpec.validate(spec, context),
         {:ok, draft} <- ExerciseDraft.new(spec, ExerciseDraft.to_map(draft)) do
      exercise = %__MODULE__{spec: spec, draft: draft}

      case AI.question_errors(to_question(exercise)) do
        [] ->
          {:ok, exercise}

        errors ->
          {:error,
           BuildError.new(:invalid_question, :build, "La consigne ou sa structure est invalide.",
             details: %{"errors" => errors}
           )}
      end
    end
  end

  def build(_, _, _),
    do: {:error, BuildError.new(:invalid_contract, :build, "Contrat et brouillon typés requis.")}

  @doc "Produces the existing question map, preserving every fixed field and provenance marker."
  def to_question(%__MODULE__{spec: spec, draft: draft}) do
    Map.merge(spec.question, %{
      "id" => spec.id,
      "plan_id" => spec.id,
      "prompt" => draft.prompt,
      "exercise_spec_id" => spec.id,
      "exercise_spec_hash" => spec.hash,
      "exercise_spec_version" => spec.version,
      "structural_validation" => "valid",
      "pedagogical_audit" => "pending"
    })
  end

  @doc "Serializes the inputs and explicitly separate structural and pedagogical statuses."
  def to_map(%__MODULE__{} = exercise) do
    %{
      "version" => 1,
      "spec" => ExerciseSpec.to_map(exercise.spec),
      "draft" => ExerciseDraft.to_map(exercise.draft),
      "structural_validation" => "valid",
      "pedagogical_audit" => "pending"
    }
  end

  @doc "Revalidates persisted inputs; a claimed audit verdict in JSON is never trusted."
  def from_map(map, context) when is_map(map) and not is_struct(map) do
    if Enum.sort(Map.keys(map)) == ~w(draft pedagogical_audit spec structural_validation version) and
         map["version"] == 1 and map["structural_validation"] == "valid" and
         map["pedagogical_audit"] == "pending" do
      with {:ok, spec} <- ExerciseSpec.from_map(map["spec"], context),
           {:ok, draft} <- ExerciseDraft.from_map(map["draft"], spec),
           do: build(spec, draft, context)
    else
      {:error,
       BuildError.new(
         :invalid_contract,
         :build,
         "Exercice persisté invalide ou statut d’audit non vérifié."
       )}
    end
  end

  def from_map(_, _),
    do:
      {:error,
       BuildError.new(:invalid_contract, :build, "Un objet d’exercice persisté est requis.")}
end
