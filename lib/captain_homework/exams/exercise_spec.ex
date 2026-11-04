defmodule CaptainHomework.Exams.ExerciseSpec do
  @moduledoc """
  Versioned, immutable inputs for writing one exercise's instruction.

  `new/2` accepts a plan slot and a context with `:sources`, `:images`, `:supports`
  and `:types`. It freezes the answer, marking scheme, visible documents and source
  identities before drafting. Only the eventual `prompt` is left to the draft.

  Dependencies are checked by identity and content metadata, not by reading files.
  Callers must preflight actual files and can supply `content_hash` to detect byte
  changes under the same storage key. Structural validity does not establish the
  truth of a source, an answer or the pedagogical quality of the instruction.
  """
  alias CaptainHomework.{AI, ImageCrops, ResponseFormats}
  alias CaptainHomework.Exams.{AnswerBasis, BuildError, Constraints, Plan}

  @version 1
  @fields ~w(type objective skill response_effort answer_basis expected_elements source_page_ids support_id image_ids image_regions support_text support_title answer rubric points options slots diagram audio_script text metadata)
  @defaults %{
    "support_id" => "",
    "image_ids" => [],
    "image_regions" => [],
    "support_text" => "",
    "support_title" => "",
    "options" => [],
    "slots" => [],
    "diagram" => nil,
    "audio_script" => nil,
    "text" => "",
    "metadata" => %{}
  }
  @dependency_fields ~w(id text kind document_kind storage_key content_type resource_id status extracted_from_id content_hash)
  @support_fields ~w(id title text image_ids image_regions)
  @persisted ~w(version id hash task initial_prompt question dependencies)

  @enforce_keys [:id, :hash, :task, :question, :dependencies]
  defstruct [:id, :hash, :task, :initial_prompt, :question, :dependencies, version: @version]

  @doc "Freezes a complete slot's essential content and all referenced dependencies."
  def new(slot, context) when is_map(slot) and not is_struct(slot) and is_map(context) do
    id = slot["plan_id"] || slot["id"]
    initial_prompt = slot["prompt"]
    task = slot["task"] || initial_prompt
    question = Map.merge(@defaults, Map.take(slot, @fields))

    with :ok <- identity(id, task, initial_prompt),
         :ok <- json_value(question),
         {:ok, question} <- attach_support(question, context),
         :ok <- validate_question(question, context),
         {:ok, dependencies} <- dependencies(question, context),
         :ok <- validate_compatibility(question, context) do
      spec = %__MODULE__{
        id: id,
        hash: "",
        task: task,
        initial_prompt: initial_prompt,
        question: question,
        dependencies: dependencies
      }

      {:ok, %{spec | hash: fingerprint(spec)}}
    end
  end

  def new(_, _),
    do: failure(:invalid_contract, "Un objet de contrat et son contexte sont requis.")

  @doc "Checks the frozen payload and verifies its dependencies against the current context."
  def validate(%__MODULE__{} = spec, context) when is_map(context) do
    with :ok <- identity(spec.id, spec.task, spec.initial_prompt),
         :ok <- json_value(spec.question),
         :ok <- json_value(spec.dependencies),
         true <- spec.version == @version and spec.hash == fingerprint(spec),
         true <-
           is_map(spec.question) and Enum.sort(Map.keys(spec.question)) == Enum.sort(@fields),
         :ok <- validate_question(spec.question, context),
         {:ok, current} <- dependencies(spec.question, context) do
      if current == spec.dependencies,
        do: validate_compatibility(spec.question, context),
        else: failure(:stale_dependency, "Une source ou une illustration du contrat a changé.")
    else
      false -> failure(:contract_mismatch, "L’empreinte ou la structure du contrat a changé.")
      error -> error
    end
  end

  def validate(_, _), do: failure(:invalid_contract, "Contrat d’exercice invalide.")

  @doc "Serializes the full contract. The hash detects accidental changes, not malicious tampering."
  def to_map(%__MODULE__{} = spec) do
    %{
      "version" => spec.version,
      "id" => spec.id,
      "hash" => spec.hash,
      "task" => spec.task,
      "initial_prompt" => spec.initial_prompt,
      "question" => spec.question,
      "dependencies" => spec.dependencies
    }
  end

  @doc "Loads a persisted contract only after checking its shape, hash and live dependency metadata."
  def from_map(map, context) when is_map(map) and not is_struct(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(@persisted) do
      spec = %__MODULE__{
        version: map["version"],
        id: map["id"],
        hash: map["hash"],
        task: map["task"],
        initial_prompt: map["initial_prompt"],
        question: map["question"],
        dependencies: map["dependencies"]
      }

      with :ok <- validate(spec, context), do: {:ok, spec}
    else
      failure(:invalid_contract, "Champs de contrat persisté invalides.")
    end
  end

  def from_map(_, _), do: failure(:invalid_contract, "Un objet de contrat persisté est requis.")

  defp identity(id, task, initial_prompt) do
    if text?(id) and byte_size(id) <= 100 and text?(task) and
         (is_nil(initial_prompt) or text?(initial_prompt)),
       do: :ok,
       else: failure(:invalid_contract, "Identifiant et tâche explicite requis pour le contrat.")
  end

  defp attach_support(%{"support_id" => ""} = question, _), do: {:ok, question}

  defp attach_support(question, context) do
    with {:ok, support} <- dependency(context, :supports, question["support_id"]),
         true <- is_binary(support["text"]) and is_binary(support["title"]),
         true <- compatible_text?(question["support_text"], support["text"]),
         true <- compatible_text?(question["support_title"], support["title"]),
         {:ok, ids, regions} <- merge_images(question, support) do
      {:ok,
       Map.merge(question, %{
         "support_text" => support["text"],
         "support_title" => support["title"],
         "image_ids" => ids,
         "image_regions" => regions
       })}
    else
      false ->
        failure(:invalid_contract, "Le document partagé contredit le contenu figé du slot.")

      error ->
        error
    end
  end

  defp compatible_text?(existing, value), do: existing in ["", value]

  defp merge_images(question, support) do
    own_ids = question["image_ids"]
    shared_ids = Map.get(support, "image_ids") || []
    own_regions = question["image_regions"]
    shared_regions = Map.get(support, "image_regions") || []

    with :ok <- ImageCrops.validate(own_ids, own_regions),
         :ok <- ImageCrops.validate(shared_ids, shared_regions) do
      own = Map.new(own_ids, &{&1, region(own_regions, &1)})
      shared = Map.new(shared_ids, &{&1, region(shared_regions, &1)})

      conflicts =
        Enum.filter(own_ids, fn id ->
          Map.has_key?(shared, id) and
            (own[id] || whole_image(id)) != (shared[id] || whole_image(id))
        end)

      if conflicts == [] do
        ids = Enum.uniq(own_ids ++ shared_ids)
        regions = Map.merge(own, shared)

        # ImageCrops requires either no crops or an explicit crop for every image.
        crops =
          if Enum.all?(regions, fn {_, crop} -> is_nil(crop) end),
            do: [],
            else: Enum.map(ids, &(regions[&1] || whole_image(&1)))

        {:ok, ids, crops}
      else
        failure(:invalid_contract, "Deux cadrages différents utilisent la même illustration.", %{
          "image_ids" => conflicts
        })
      end
    else
      _ -> failure(:invalid_contract, "Les illustrations ou leurs cadrages sont invalides.")
    end
  end

  defp region(regions, id), do: Enum.find(regions, &(&1["image_id"] == id))

  defp whole_image(id),
    do: %{"image_id" => id, "x" => 0, "y" => 0, "width" => 1000, "height" => 1000}

  defp validate_question(question, context) when is_map(question) do
    types = Map.get(context, :types, ResponseFormats.ids())

    valid =
      is_list(types) and question["type"] in types and text?(question["objective"]) and
        question["skill"] in Plan.skills() and
        question["response_effort"] in ~w(direct short developed) and
        question["answer_basis"] in ~w(knowledge document) and
        text_list?(question["expected_elements"], false) and
        text_list?(question["source_page_ids"], false) and
        text_list?(question["image_ids"], true) and
        is_binary(question["support_id"]) and is_binary(question["support_text"]) and
        is_binary(question["support_title"]) and is_map(question["metadata"]) and
        (question["type"] not in ~w(cloze diagram listening) or question["support_id"] == "")

    if valid do
      # The instruction does not exist yet. Validate only the fixed payload here.
      errors = AI.question_errors(Map.put(question, "prompt", "Consigne à rédiger."))

      cond do
        errors != [] ->
          failure(:invalid_contract, "Le contenu figé de l’exercice est invalide.", %{
            "errors" => errors
          })

        true ->
          :ok
      end
    else
      failure(:invalid_contract, "Métadonnées pédagogiques ou références du contrat invalides.")
    end
  end

  defp validate_question(_, _), do: failure(:invalid_contract, "Contenu du contrat invalide.")

  defp validate_compatibility(question, context) do
    sources = Map.get(context, :sources, [])

    pages =
      if is_list(sources),
        do:
          for(
            source <- sources,
            is_map(source),
            do: %{id: field(source, "id"), kind: field(source, "kind")}
          ),
        else: []

    basis_errors =
      AnswerBasis.validation_errors([Map.put(question, "id", "exercise")], pages, [])

    if basis_errors == [] and
         Constraints.compatible?(
           question["type"],
           question["response_effort"],
           question["answer_basis"],
           pages
         ),
       do: :ok,
       else:
         failure(
           :incompatible_constraints,
           "Le format, l’effort ou le mode de réponse est incompatible avec les sources.",
           %{"errors" => basis_errors}
         )
  end

  defp dependencies(question, context) do
    support_ids = if question["support_id"] == "", do: [], else: [question["support_id"]]

    Enum.reduce_while(
      [
        {:sources, question["source_page_ids"]},
        {:images, question["image_ids"]},
        {:supports, support_ids}
      ],
      {:ok, %{}},
      fn {kind, ids}, {:ok, result} ->
        case dependency_hashes(context, kind, ids) do
          {:ok, hashes} -> {:cont, {:ok, Map.put(result, Atom.to_string(kind), hashes)}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp dependency_hashes(context, kind, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, result} ->
      case dependency(context, kind, id) do
        {:ok, value} ->
          fields = if kind == :supports, do: @support_fields, else: @dependency_fields
          payload = Map.new(fields, &{&1, Map.get(value, &1)})

          case json_value(payload) do
            :ok -> {:cont, {:ok, Map.put(result, id, digest(payload))}}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp dependency(context, kind, id) do
    entries = Map.get(context, kind, [])

    matches =
      if is_list(entries),
        do: Enum.filter(entries, &(is_map(&1) and field(&1, "id") == id)),
        else: []

    case matches do
      [entry] ->
        fields = if kind == :supports, do: @support_fields, else: @dependency_fields
        entry = Map.new(fields, &{&1, field(entry, &1)})

        if entry["status"] in [nil, "ready"],
          do: {:ok, entry},
          else:
            failure(:missing_dependency, "Une dépendance n’est pas prête.", %{
              "kind" => to_string(kind),
              "id" => id
            })

      _ ->
        failure(
          :missing_dependency,
          "Une dépendance est absente ou son identifiant est ambigu.",
          %{
            "kind" => to_string(kind),
            "id" => id
          }
        )
    end
  end

  defp field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(Map.to_list(map), fn {key, value} ->
          if is_atom(key) and Atom.to_string(key) == field, do: {:found, value}
        end)
        |> unwrap()
    end
  end

  defp unwrap({:found, value}), do: value
  defp unwrap(nil), do: nil

  defp fingerprint(spec), do: spec |> to_map() |> Map.delete("hash") |> digest()

  defp digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp text_list?(value, empty?) do
    is_list(value) and (empty? or value != []) and Enum.all?(value, &text?/1) and
      length(value) == length(Enum.uniq(value))
  end

  defp json_value(value) do
    if json?(value),
      do: :ok,
      else: failure(:invalid_contract, "Le contrat doit contenir uniquement des valeurs JSON.")
  end

  defp json?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json?(item) end)

  defp json?(_), do: false

  defp failure(kind, message, details \\ %{}),
    do: {:error, BuildError.new(kind, :spec, message, details: details)}
end
