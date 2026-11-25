defmodule CaptainHomework.Exams.TypeContract do
  @moduledoc "Executable catalogue rules, resolved from the exam's immutable type snapshots."
  alias CaptainHomework.{QuestionDefinitions, QuestionTemplates}
  alias CaptainHomework.Exams.{BuildError, Listening}
  alias CaptainHomework.Study.QuestionDefinition

  def context(definitions, mode, subject) do
    %{
      definitions: Enum.map(definitions, &snapshot/1),
      mode: mode,
      subject: subject
    }
  end

  defp snapshot(%QuestionDefinition{} = definition), do: QuestionDefinitions.snapshot(definition)
  defp snapshot(definition), do: definition

  # Old controls without catalogue references retain the legacy format validation.
  # Missing IDs can be recovered only when the selected format identifies exactly one type.
  def bind(question, context) do
    definitions = Map.get(context, :definitions, [])
    id = question["definition_id"]

    matches =
      Enum.filter(definitions, fn definition ->
        if id in [nil, ""],
          do: format(definition) == question["type"],
          else: definition["id"] == id
      end)

    case {definitions, matches} do
      {[], []} ->
        if is_nil(question["type_contract"]),
          do: {:ok, question},
          else: failure("Type enregistré absent de l’évaluation.")

      {_, [definition]} ->
        contract =
          Map.put(
            definition,
            "instruction",
            QuestionTemplates.render(definition["instruction"], context[:subject])
          )

        cond do
          question["type"] != format(definition) ->
            failure("Le format de réponse ne correspond pas au type sélectionné.")

          context[:mode] not in definition["modes"] ->
            failure("Ce type n’est pas autorisé dans ce mode d’évaluation.")

          context[:subject] not in definition["subjects"] ->
            failure("Ce type n’est pas autorisé dans cette matière.")

          question["type_contract"] not in [nil, contract] ->
            failure("Les règles du type ne correspondent plus au contrat enregistré.")

          true ->
            {:ok,
             Map.merge(question, %{
               "definition_id" => definition["id"],
               "type_contract" => contract
             })}
        end

      _ ->
        failure(
          "Le type exact de la question est absent, ambigu ou non autorisé : definition_id est requis."
        )
    end
  end

  def fixed_prompt(%{
        "type_contract" => %{"instruction_kind" => "fixed", "instruction" => instruction}
      }),
      do: instruction

  def fixed_prompt(_), do: nil

  def errors(question, phase \\ :final)

  def errors(%{"type_contract" => %{} = contract} = question, phase) do
    prompt = fixed_prompt(question)

    checks = [
      {phase == :spec or is_nil(prompt) or question["prompt"] == prompt,
       "La consigne fixe du type doit être conservée à l’identique."},
      {contract["instruction_kind"] != "fixed" or text?(prompt),
       "La consigne fixe du type est vide."},
      {content_valid?(question, contract), content_message(question, contract)}
    ]

    base_errors = for {false, message} <- checks, do: message

    field_errors =
      for {key, value} <- constants(contract, phase, nil),
          key not in ["task", "prompt"] and Map.has_key?(question, key) and question[key] != value,
          do: "Le champ #{key} n’est pas autorisé pour le type #{contract["name"]}."

    base_errors ++ field_errors ++ CaptainHomework.Exams.VisibleSupport.errors(question)
  end

  def errors(_, _), do: []

  def validate(question, context, phase \\ :final) do
    with {:ok, question} <- bind(question, context) do
      case errors(question, phase) do
        [] -> {:ok, question}
        errors -> failure(Enum.join(errors, " "))
      end
    end
  end

  defp content_message(question, contract) do
    kinds = QuestionDefinition.content_kinds(contract)

    cond do
      contract["content_presence"] == "none" ->
        "Le type #{contract["name"]} ne permet pas de contenu supplémentaire."

      kinds == ["text"] and not text?(question["text"]) and
          not text?(question["support_text"]) ->
        "Le texte à traiter est manquant pour le type #{contract["name"]} (champ text)."

      true ->
        "Le contenu fourni ne correspond pas aux natures autorisées pour le type #{contract["name"]} (#{Enum.join(kinds, ", ")})."
    end
  end

  defp content_valid?(question, contract) do
    text = text?(question["text"]) or text?(question["support_text"])

    image =
      present_list?(question["image_ids"]) or present_list?(question["images"]) or
        is_map(question["diagram"])

    audio = not is_nil(question["audio_script"]) or not is_nil(question["audio"])

    # Choices and ordering items belong to the response format; ordering items also supply its content.
    ordered_text = question["type"] == "ordering" and present_list?(question["options"])
    present = text or image or audio or ordered_text
    kinds = QuestionDefinition.content_kinds(contract)

    expected =
      if kinds == ["audio"] do
        Listening.valid_script?(question["audio_script"]) and not text and not image
      else
        image_allowed? = "image" in kinds or "document" in kinds

        not audio and (not image or image_allowed?) and
          ((image and image_allowed?) or (text and "document" in kinds) or
             ((text or ordered_text) and "text" in kinds))
      end

    case contract["content_presence"] do
      "none" -> not present
      "optional" -> not present or expected
      "required" -> expected
      _ -> false
    end
  end

  @doc "Fields owned by the application, shared by schema generation and assembly."
  def constants(definition, phase, subject) do
    format = format(definition)
    kinds = QuestionDefinition.content_kinds(definition)
    absent? = definition["content_presence"] == "none"
    document? = "document" in kinds and not absent?
    images? = document? or ("image" in kinds and not absent?)

    %{}
    |> constant("options", [], format not in ~w(mcq ordering))
    |> constant("slots", [], format not in ~w(cloze diagram))
    |> constant("diagram", nil, format != "diagram")
    |> constant("audio_script", nil, "audio" not in kinds or absent?)
    |> constant("image_ids", [], not images?)
    |> constant("image_regions", [], not images?)
    |> constant(
      "support_id",
      "",
      not document? or format in ~w(cloze diagram listening)
    )
    |> constant("support_text", "", not document?)
    |> constant("support_title", "", not document?)
    |> constant("text", "", "audio" in kinds or absent?)
    |> constant("answer_basis", "knowledge", absent?)
    |> constant(
      if(phase == :spec, do: "task", else: "prompt"),
      QuestionTemplates.render(definition["instruction"], subject),
      definition["instruction_kind"] == "fixed"
    )
  end

  defp constant(values, key, value, true), do: Map.put(values, key, value)
  defp constant(values, _, _, false), do: values

  @doc "Restores omitted application fields; conflicting supplied values are never overwritten."
  def assemble(question, context, phase) do
    with {:ok, bound} <- bind(question, context) do
      case bound["type_contract"] do
        nil ->
          {:ok, bound}

        definition ->
          constants = constants(definition, phase, context[:subject])

          conflicts =
            for {key, value} <- constants,
                Map.has_key?(question, key) and question[key] != value,
                do: key

          if conflicts == [],
            do: {:ok, Map.merge(bound, constants)},
            else:
              failure(
                "Champs fixés par le type #{definition["name"]} modifiés : #{Enum.join(conflicts, ", ")}."
              )
      end
    end
  end

  @doc "Derives the model's writable fields from the selected types, including retained fields."
  def schema(properties, context, frozen \\ %{}, phase \\ :final) do
    properties =
      properties
      |> Map.delete(if(phase == :spec, do: "prompt", else: "task"))
      |> constrain("task", %{"pattern" => "\\S"})

    catalogue = Map.get(context, :definitions, [])
    allowed = properties["type"]["enum"]

    definitions =
      Enum.filter(catalogue, fn definition ->
        (is_nil(allowed) or format(definition) in allowed) and
          context[:mode] in definition["modes"] and context[:subject] in definition["subjects"]
      end)

    definitions =
      if frozen["definition_id"],
        do: Enum.filter(definitions, &(&1["id"] == frozen["definition_id"])),
        else: definitions

    variants =
      Enum.flat_map(definitions, fn definition ->
        fields =
          properties
          |> Map.put("definition_id", %{"type" => "string", "enum" => [definition["id"]]})
          |> Map.put("type", %{"type" => "string", "enum" => [format(definition)]})
          |> Map.drop(Map.keys(constants(definition, phase, context[:subject])))
          |> Map.drop(Map.keys(frozen))
          |> response_schema(format(definition), context[:mode])

        content_variants(fields, definition, frozen)
      end)

    case variants do
      [] ->
        if(catalogue == [],
          do: object(Map.drop(properties, Map.keys(frozen))),
          else: %{"anyOf" => []}
        )

      [single] ->
        single

      many ->
        %{"anyOf" => many}
    end
  end

  @doc "Rejects impossible branches locally instead of paying for an unsatisfiable request."
  def schema_possible?(%{"anyOf" => variants}), do: Enum.any?(variants, &schema_possible?/1)

  def schema_possible?(%{"properties" => properties}),
    do: Enum.all?(Map.values(properties), &schema_possible?/1)

  def schema_possible?(%{"type" => "array"} = schema) do
    minimum = schema["minItems"] || 0

    (is_nil(schema["maxItems"]) or minimum <= schema["maxItems"]) and
      schema_possible?(schema["items"])
  end

  def schema_possible?(%{"enum" => values, "pattern" => pattern}),
    do: Enum.any?(values, &Regex.match?(Regex.compile!(pattern), &1))

  def schema_possible?(%{"enum" => values}), do: values != []
  def schema_possible?(_), do: true

  defp response_schema(fields, format, mode) do
    case format do
      "mcq" ->
        constrain(fields, "options", %{"minItems" => 2, "maxItems" => 6})

      "ordering" ->
        constrain(fields, "options", %{
          "minItems" => 2,
          "maxItems" => if(mode == "flashcard", do: 4, else: 8)
        })

      "cloze" ->
        fields
        |> constrain("slots", %{"minItems" => 1})
        |> constrain("text", %{"pattern" => "\\S"})

      "diagram" ->
        fields |> constrain("slots", %{"minItems" => 1}) |> required_object("diagram")

      "listening" ->
        required_object(fields, "audio_script")

      "pronunciation" ->
        constrain(fields, "text", %{"pattern" => "\\S"})

      _ ->
        fields
    end
  end

  defp required_object(fields, key) do
    if Map.has_key?(fields, key), do: require_content(fields, key), else: fields
  end

  defp content_variants(fields, %{"content_presence" => "required"} = definition, frozen) do
    candidates =
      definition
      |> QuestionDefinition.content_kinds()
      |> Enum.flat_map(&content_fields(&1, format(definition)))
      |> Enum.uniq()

    if Enum.any?(candidates, &(frozen[&1] not in [nil, "", []])) do
      [object(fields)]
    else
      for key <- candidates,
          Map.has_key?(fields, key),
          schema_possible?(require_content(fields, key)[key]),
          do: object(require_content(fields, key))
    end
  end

  defp content_variants(fields, _, _), do: [object(fields)]

  defp content_fields("text", "ordering"), do: ["options"]
  defp content_fields("text", _), do: ["text"]
  defp content_fields("image", "diagram"), do: ["diagram"]
  defp content_fields("image", _), do: ["image_ids"]
  defp content_fields("audio", _), do: ["audio_script"]
  defp content_fields("document", _), do: ["text", "image_ids", "support_id"]

  defp require_content(fields, key) when key in ~w(text support_id) do
    fields = constrain(fields, key, %{"pattern" => "\\S"})

    case fields[key] do
      %{"enum" => values} ->
        # The provider requires every enum value to satisfy the pattern, even
        # when other enum values would make this branch satisfiable.
        put_in(fields, [key, "enum"], Enum.filter(values, &text?/1))

      _ ->
        fields
    end
  end

  defp require_content(fields, key) when key in ~w(image_ids options),
    do: constrain(fields, key, %{"minItems" => max(fields[key]["minItems"] || 0, 1)})

  defp require_content(fields, key) do
    Map.update!(fields, key, fn schema ->
      case schema do
        %{"anyOf" => variants} -> Enum.find(variants, &(&1["type"] != "null"))
        _ -> schema
      end
    end)
  end

  defp constrain(fields, key, constraints) do
    if Map.has_key?(fields, key),
      do: Map.update!(fields, key, &Map.merge(&1, constraints)),
      else: fields
  end

  defp object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }

  defp format(definition) do
    QuestionDefinitions.engine_format(%{
      content_kinds: QuestionDefinition.content_kinds(definition),
      response_kind: definition["response_kind"]
    })
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp present_list?(value), do: is_list(value) and value != []

  defp failure(message),
    do: {:error, BuildError.new(:invalid_type_contract, :specification, message)}
end
