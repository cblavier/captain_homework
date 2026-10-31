import Config

config :captain_homework, CaptainHomeworkWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :captain_homework, :secure_cookies, true
config :logger, level: :info
