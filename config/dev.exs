import Config

config :captain_homework, CaptainHomeworkWeb.Endpoint,
  # Accessible depuis un reverse proxy sur le réseau local.
  http: [ip: {0, 0, 0, 0}, port: 4125],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "captain_homework_development_only_0123456789abcdef0123456789abcdef0123456789",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:captain_homework, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [~r"priv/static/.*(js|css|svg)$", ~r"lib/captain_homework_web/.*(ex|heex)$"]
  ]

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true,
  debug_heex_annotations: true,
  debug_attributes: true
