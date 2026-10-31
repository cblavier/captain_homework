defmodule CaptainHomework.AI do
  @callback transcribe(binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback analyze_resource(binary(), String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks analyze_resource: 2
  @callback generate(map(), list(), list(), integer(), String.t(), list()) ::
              {:ok, list()} | {:error, term()}
  @callback grade(map()) :: {:ok, list()} | {:error, term()}
  def provider, do: Application.fetch_env!(:captain_homework, :ai_provider)
  def transcribe(data, type), do: provider().transcribe(data, type)

  def analyze_resource(data, type) do
    if Code.ensure_loaded?(provider()) and function_exported?(provider(), :analyze_resource, 2) do
      provider().analyze_resource(data, type)
    else
      with {:ok, text} <- transcribe(data, type),
           do: {:ok, %{"text" => text, "document_kind" => "other"}}
    end
  end

  def generate(lesson, pages, examples, count, instructions, retries),
    do: provider().generate(lesson, pages, examples, count, instructions, retries)

  def grade(exam), do: provider().grade(exam)

  def configured?,
    do:
      provider() != CaptainHomework.AI.OpenAI or
        (Application.get_env(:captain_homework, :openai_api_key) || "") != ""

  def message(reason) when is_binary(reason), do: reason
  def message(_), do: "Le service IA est indisponible. Réessaie dans un instant."

  def validate_questions(questions, expected) do
    {valid, errors} = inspect_questions(questions)

    errors =
      if length(valid) == expected,
        do: errors,
        else: errors ++ ["#{length(valid)} questions valides reçues pour #{expected} attendues"]

    if errors == [], do: {:ok, valid}, else: {:error, Enum.join(errors, "; ")}
  end

  def inspect_questions(questions) when is_list(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {q, index}, {valid, errors} ->
      case question_errors(q) do
        [] -> {valid ++ [q], errors}
        reasons -> {valid, errors ++ Enum.map(reasons, &"Question #{index} : #{&1}")}
      end
    end)
  end

  def inspect_questions(_), do: {[], ["La réponse doit contenir une liste de questions"]}

  def question_errors(q) when is_map(q) do
    image_ids = Map.get(q, "image_ids", [])

    checks = [
      {is_list(image_ids) and length(image_ids) <= 6 and Enum.all?(image_ids, &is_binary/1),
       "illustrations : liste de six identifiants maximum attendue"},
      {q["type"] in ~w(definition mcq cloze reading long diagram), "type de question inconnu"},
      {Enum.all?(~w(prompt answer rubric), &(is_binary(q[&1]) and String.trim(q[&1]) != "")),
       "énoncé, réponse ou barème manquant"},
      {is_integer(q["points"]) and q["points"] in 1..8, "points : entier de 1 à 8 attendu"},
      {is_binary(q["text"]), "texte attendu"},
      {is_list(q["options"]) and Enum.all?(q["options"], &is_binary/1),
       "options : liste de textes attendue"},
      {is_list(q["slots"]) and length(q["slots"]) <= 20 and
         Enum.all?(q["slots"], &(is_binary(&1) and Regex.match?(~r/^[1-9][0-9]?$/, &1))) and
         Enum.uniq(q["slots"]) == q["slots"], "champs : numéros uniques de 1 à 99 attendus"}
    ]

    errors = for {false, reason} <- checks, do: reason
    if errors == [], do: type_errors(q), else: errors
  end

  def question_errors(_), do: ["objet question attendu"]

  defp type_errors(q) do
    case q["type"] do
      "mcq" ->
        if length(q["options"]) in 2..6 and Enum.uniq(q["options"]) == q["options"] and
             q["answer"] in q["options"],
           do: [],
           else: ["QCM : 2 à 6 choix distincts et réponse identique à un choix requis"]

      "reading" ->
        if String.trim(q["text"]) != "", do: [], else: ["texte de compréhension absent"]

      "cloze" ->
        holes =
          Regex.scan(~r/\{\{(\d+)\}\}/, q["text"], capture: :all_but_first)
          |> List.flatten()
          |> Enum.uniq()
          |> Enum.sort()

        if q["slots"] != [] and holes == Enum.sort(q["slots"]),
          do: [],
          else: [
            "texte à trous : correspondance exacte requise entre les {{numéros}} et les champs"
          ]

      "diagram" ->
        if valid_diagram?(q["diagram"], q["slots"]),
          do: [],
          else: [
            "schéma : formes, dimensions ou correspondance des numéros invalides ; remplacer par une définition si nécessaire"
          ]

      _ ->
        if q["slots"] == [] and q["options"] == [] and is_nil(q["diagram"]),
          do: [],
          else: ["question simple : slots et options doivent être vides, diagram doit être null"]
    end
  end

  defp valid_diagram?(%{"nodes" => nodes}, slots)
       when is_list(nodes) and length(nodes) in 1..20 do
    slots != [] and
      Enum.all?(nodes, fn n ->
        is_map(n) and n["shape"] in ~w(rect ellipse) and n["label"] in slots and
          Enum.all?(~w(x y width height), &(is_number(n[&1]) and n[&1] >= 0 and n[&1] <= 500)) and
          n["width"] > 0 and n["height"] > 0 and n["x"] + n["width"] <= 500 and
          n["y"] + n["height"] <= 300
      end) and Enum.sort(Enum.map(nodes, & &1["label"])) == Enum.sort(slots)
  end

  defp valid_diagram?(_, _), do: false
end
