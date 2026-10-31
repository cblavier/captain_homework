import Config

config :captain_homework,
  ecto_repos: [CaptainHomework.Repo],
  ai_provider: CaptainHomework.AI.OpenAI

config :captain_homework, CaptainHomework.Repo,
  database: Path.expand("../data/captain_homework.db", __DIR__),
  pool_size: 1,
  log: false,
  journal_mode: :wal,
  default_transaction_mode: :immediate,
  busy_timeout: 5_000

config :captain_homework, CaptainHomeworkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CaptainHomeworkWeb.ErrorHTML, json: CaptainHomeworkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CaptainHomework.PubSub,
  live_view: [signing_salt: "homework-live-v1"]

config :esbuild,
  version: "0.25.4",
  captain_homework: [
    args:
      ~w(js/app.js js/startup.js css/app.css --bundle --target=es2022 --outbase=. --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "key",
  "answers",
  "text",
  "instructions"
]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
