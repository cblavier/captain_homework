import Config

config :captain_homework, :family_env, %{
  "HOMEWORK_CHILD_1_FIRST_NAME" => "Alice",
  "HOMEWORK_CHILD_2_FIRST_NAME" => "Marius",
  "HOMEWORK_CHILD_3_FIRST_NAME" => "Bob"
}

config :captain_homework, CaptainHomework.Repo,
  database: Path.expand("../data/test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :captain_homework, uploads_dir: Path.expand("../tmp/test-uploads", __DIR__)

config :captain_homework, CaptainHomeworkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4126],
  secret_key_base: "captain_homework_test_only_0123456789abcdef0123456789abcdef0123456789",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
