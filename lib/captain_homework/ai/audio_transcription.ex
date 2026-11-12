defmodule CaptainHomework.AI.AudioTranscription do
  @moduledoc false

  def transcribe(data) when byte_size(data) <= 25_000_000 do
    key = Application.get_env(:captain_homework, :openai_api_key)

    if key in [nil, ""] do
      {:error, "La connexion IA n’est pas encore configurée."}
    else
      options =
        Keyword.merge(
          [
            auth: {:bearer, key},
            form_multipart: [
              model:
                Application.get_env(
                  :captain_homework,
                  :openai_transcription_model,
                  "gpt-transcribe"
                ),
              response_format: "json",
              file: {data, filename: "audio.mp3", content_type: "audio/mpeg"}
            ],
            receive_timeout: 180_000,
            retry: false
          ],
          Application.get_env(:captain_homework, :openai_request_options, [])
        )

      case Req.post("https://api.openai.com/v1/audio/transcriptions", options) do
        {:ok, %{status: 200, body: %{"text" => text}}} when is_binary(text) ->
          {:ok, text}

        {:ok, %{status: 401}} ->
          {:error, "La clé OpenAI doit être vérifiée dans la configuration."}

        {:ok, %{status: 429}} ->
          {:error, "Le quota OpenAI est atteint. Vérifie les crédits API ou réessaie plus tard."}

        _ ->
          {:error, "Le service IA n’a pas pu transcrire l’audio. Réessaie."}
      end
    end
  rescue
    _ -> {:error, "Le service de transcription audio est inaccessible. Réessaie."}
  end

  def transcribe(_),
    do: {:error, "L’extrait audio dépasse la taille autorisée pour la transcription."}
end
