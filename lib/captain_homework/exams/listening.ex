defmodule CaptainHomework.Exams.Listening do
  @moduledoc "Listening scripts stay server-side; only the generated audio is delivered to pupils."
  alias CaptainHomework.{AI, Uploads}

  def instructions do
    """
    Pour listening (compréhension orale), crée un monologue court de 25 à 90 mots dans la langue
    étudiée, adapté au vocabulaire et aux compétences des sources. audio_script contient text
    (les mots exacts à prononcer, sans didascalies), language (en, es ou fr), et speaker_gender
    (female, male ou neutral). Choisis le genre selon le personnage qui PARLE, pas celui dont
    il parle. Si tu crées un personnage, choisis explicitement une voix cohérente ; si le genre
    n'est pas indiqué, utilise neutral sans le déduire du seul prénom. Un seul locuteur par extrait.
    prompt demande d'écouter puis de répondre à UNE question précise dans la langue étudiée.
    La réponse doit être présente dans l'extrait entendu. answer_basis=document, response_effort=direct,
    support_id="", text="", options=[], slots=[], diagram=null et image_ids=[].
    La transcription audio_script.text est réservée à la synthèse et à la correction : elle n'est
    jamais affichée à l'élève, mais l'audio est un support fourni, pas une connaissance à mémoriser.
    N'affiche ni transcription ni traduction de l'extrait dans prompt ou dans un support partagé.
    Pour tous les autres types, audio_script=null.
    """
  end

  def errors(%{"type" => "listening"} = q) do
    if valid_script?(q["audio_script"]) and q["text"] == "" and
         q["support_id"] in [nil, ""] and q["support_text"] in [nil, ""] and
         Map.get(q, "image_ids", []) == [] and q["answer_basis"] in [nil, "document"],
       do: [],
       else: [
         "Compréhension orale : un extrait valide est requis, sans transcription visible ni support partagé."
       ]
  end

  def errors(q) do
    if is_nil(q["audio_script"]),
      do: [],
      else: ["Un extrait audio est réservé au type listening."]
  end

  def valid_script?(%{"text" => text, "language" => language, "speaker_gender" => gender}) do
    is_binary(text) and String.length(String.trim(text)) in 20..2000 and
      language in ~w(en es fr) and gender in ~w(female male neutral)
  end

  def valid_script?(_), do: false

  def prepare(questions, on_audio \\ fn _question -> :ok end) do
    Enum.reduce_while(questions, {[], []}, fn q, {ready, errors} ->
      if q["type"] == "listening", do: on_audio.(q)

      case materialize(q) do
        {:ok, q} -> {:cont, {ready ++ [q], errors}}
        {:error, reason} -> {:halt, {ready, errors ++ [AI.message(reason)]}}
      end
    end)
  end

  defp materialize(%{"type" => "listening"} = q) do
    with true <- valid_script?(q["audio_script"]),
         {:ok, data} <- AI.synthesize_speech(q["audio_script"]) do
      id = Ecto.UUID.generate()
      key = "question-#{id}.wav"
      File.mkdir_p!(Uploads.directory())

      case File.write(Uploads.path(key), data) do
        :ok ->
          {:ok,
           Map.put(q, "audio", %{"id" => id, "storage_key" => key, "content_type" => "audio/wav"})}

        {:error, _} ->
          File.rm(Uploads.path(key))
          {:error, "L’extrait audio n’a pas pu être enregistré. Réessaie la génération."}
      end
    else
      false -> {:error, "Le texte de l’extrait audio est incomplet."}
      error -> error
    end
  rescue
    _ -> {:error, "La synthèse vocale a été interrompue. Réessaie les questions manquantes."}
  end

  defp materialize(q), do: {:ok, Map.delete(q, "audio")}

  def copy(%{"audio" => %{"storage_key" => key}} = q) do
    id = Ecto.UUID.generate()
    destination = "question-#{id}#{Path.extname(key)}"
    File.cp!(Uploads.path(key), Uploads.path(destination))
    Map.put(q, "audio", Map.merge(q["audio"], %{"id" => id, "storage_key" => destination}))
  end

  def copy(q), do: q

  def delete(question) do
    if is_map(question["audio"]), do: File.rm(Uploads.path(question["audio"]["storage_key"]))
    :ok
  end
end
