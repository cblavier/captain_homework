import Config

config :captain_homework,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  openai_model: System.get_env("OPENAI_MODEL", "gpt-5.4"),
  openai_illustration_model: System.get_env("OPENAI_ILLUSTRATION_MODEL", "gpt-6-astra"),
  openai_flashcard_model: System.get_env("OPENAI_FLASHCARD_MODEL", "gpt-5.4-mini"),
  openai_speech_model: System.get_env("OPENAI_SPEECH_MODEL", "gpt-realtime-2.1-mini"),
  access_password: System.get_env("HOMEWORK_PASSWORD")

if System.get_env("PHX_SERVER") == "true",
  do: config(:captain_homework, CaptainHomeworkWeb.Endpoint, server: true)

if config_env() != :test do
  config :captain_homework,
         :family_env,
         System.get_env()
         |> Map.filter(fn {key, _} ->
           String.starts_with?(key, "HOMEWORK_CHILD_") or
             Regex.match?(~r/^PRONOTE_CHILD_[1-9][0-9]*_THEME$/, key)
         end)

  database = System.get_env("DATABASE_PATH", Path.expand("../data/captain_homework.db", __DIR__))
  config :captain_homework, CaptainHomework.Repo, database: database

  config :captain_homework,
         :uploads_dir,
         System.get_env("UPLOADS_PATH", Path.join(Path.dirname(database), "uploads"))

  config :captain_homework, CaptainHomeworkWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4125"))]
end

if config_env() == :dev do
  if host = System.get_env("PHX_HOST") do
    config :captain_homework, CaptainHomeworkWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"]
  end
end

if config_env() == :prod do
  secret = System.fetch_env!("SECRET_KEY_BASE")
  if byte_size(secret) < 64, do: raise("SECRET_KEY_BASE must have at least 64 characters")
  host = System.fetch_env!("PHX_HOST")

  config :captain_homework, CaptainHomeworkWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}"],
    http: [ip: {0, 0, 0, 0}],
    secret_key_base: secret
end
