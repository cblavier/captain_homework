defmodule CaptainHomework.AI do
  @callback transcribe(binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback analyze_resource(binary(), String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks analyze_resource: 2
  @callback extract_illustrations(binary(), String.t(), pos_integer(), String.t()) ::
              {:ok, list()} | {:error, term()}
  @optional_callbacks extract_illustrations: 4

  def extract_illustrations(data, type, count, instructions) do
    if Code.ensure_loaded?(provider()) and
         function_exported?(provider(), :extract_illustrations, 4),
       do: provider().extract_illustrations(data, type, count, instructions),
       else: {:error, "L’extraction d’illustrations n’est pas disponible avec ce service IA."}
  end

  @callback analyze_example_style(binary(), String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks analyze_example_style: 2

  @callback build_catalogue(list()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks build_catalogue: 1

  def catalogue_supported?,
    do: Code.ensure_loaded?(provider()) and function_exported?(provider(), :build_catalogue, 1)

  def build_catalogue(pages), do: provider().build_catalogue(pages)

  @callback plan_control(map(), list(), list(), integer(), String.t(), list(), list()) ::
              {:ok, map()} | {:error, term()}
  @callback repair_control_plan(
              map(),
              list(),
              list(),
              integer(),
              String.t(),
              list(),
              list(),
              map()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback generate_planned(map(), map(), list(), String.t(), list()) ::
              {:ok, list()} | {:ok, list(), map()} | {:error, term()}
  @optional_callbacks plan_control: 7, repair_control_plan: 8, generate_planned: 5

  @callback generate(map(), list(), list(), integer(), String.t(), list()) ::
              {:ok, list()} | {:error, term()}
  @callback grade(map()) :: {:ok, list() | map()} | {:error, term()}
  @callback generate_flashcards(map(), list(), integer(), String.t(), list(), list()) ::
              {:ok, list()} | {:error, term()}
  @optional_callbacks generate_flashcards: 6
  @callback select_exam_content(list(), list(), String.t()) ::
              {:ok, list(), boolean()} | {:error, term()}
  @optional_callbacks select_exam_content: 3
  @callback synthesize_speech(map()) :: {:ok, binary()} | {:error, term()}
  @optional_callbacks synthesize_speech: 1

  def synthesize_speech(script) do
    if Code.ensure_loaded?(provider()) and function_exported?(provider(), :synthesize_speech, 1),
      do: provider().synthesize_speech(script),
      else: {:error, "La synthèse vocale n’est pas disponible avec ce service IA."}
  end

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

  def message(:invalid_effort_review),
    do: "La vérification des questions n’a pas abouti. Réessaie les questions manquantes."

  def message(:invalid_plan),
    do:
      "La préparation des questions n’a pas abouti malgré une tentative de correction automatique. Réessaie la génération."

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
      {CaptainHomework.ImageCrops.validate(image_ids, Map.get(q, "image_regions", [])) == :ok,
       "recadrage : zones complètes et valides requises pour les illustrations sélectionnées"},
      {q["type"] in CaptainHomework.ResponseFormats.ids(), "type de question inconnu"},
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

    if errors == [],
      do: type_errors(q) ++ support_errors(q) ++ CaptainHomework.Exams.Listening.errors(q),
      else: errors
  end

  def question_errors(_), do: ["objet question attendu"]

  defp support_errors(q) do
    prompt = String.normalize(q["prompt"], :nfc)

    numbers =
      Regex.scan(~r/\b(?:num[eé]ro|n[°ºo])\s*(\d+)\b/iu, prompt, capture: :all_but_first)
      |> List.flatten()

    missing_list? =
      Regex.match?(~r/\bliste\b/iu, prompt) and numbers != [] and
        not visible_support?(q) and
        not Enum.all?(numbers, &listed_in_prompt?(prompt, &1))

    if missing_list?,
      do: [
        "liste numérotée absente : affiche les éléments référencés dans l’énoncé ou reformule la question pour qu’elle soit autonome"
      ],
      else: []
  end

  defp visible_support?(q) do
    images = Map.get(q, "images", [])

    String.trim(q["text"]) != "" or String.trim(q["support_text"] || "") != "" or
      Map.get(q, "image_ids", []) != [] or
      (is_list(images) and images != []) or
      (q["type"] == "ordering" and q["options"] != []) or
      (q["type"] == "diagram" and valid_diagram?(q["diagram"], q["slots"]))
  end

  defp listed_in_prompt?(prompt, number) do
    # A number mentioned in the question or an MCQ option is not a numbered source list.
    Regex.match?(~r/(?:^|[\n\r;,:])[ \t]*#{number}[ \t]*[.):\-][ \t]*\S/u, prompt)
  end

  defp type_errors(q) do
    case q["type"] do
      "mcq" ->
        if length(q["options"]) in 2..6 and Enum.uniq(q["options"]) == q["options"] and
             q["answer"] in q["options"],
           do: [],
           else: ["QCM : 2 à 6 choix distincts et réponse identique à un choix requis"]

      "ordering" ->
        if CaptainHomework.Exams.Ordering.valid_question?(q),
          do: [],
          else: [
            "classement : 2 à 8 événements distincts et réponse contenant chaque numéro une seule fois, séparé par une virgule et une espace"
          ]

      "reading" ->
        if visible_support?(q),
          do: [],
          else: ["support de compréhension absent"]

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
            "schéma : respecte le repère 500 × 300 (x + width ≤ 500 et y + height ≤ 300), les dimensions positives et les numéros de slots ; les formes sont séparées des images, pas superposées"
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
