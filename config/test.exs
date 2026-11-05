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

config :captain_homework, :accounts, [
  %{id: "family", role: :family, label: "Famille", pin: "12345678", profile_key: nil},
  %{
    id: "child-1",
    role: :child,
    label: "Alice",
    pin: "23456789",
    profile_key: "HOMEWORK_CHILD_1"
  },
  %{
    id: "child-2",
    role: :child,
    label: "Marius",
    pin: "34567890",
    profile_key: "HOMEWORK_CHILD_2"
  },
  %{id: "parent-1", role: :parent, label: "Agnès", pin: "45678901", profile_key: nil},
  %{id: "parent-2", role: :parent, label: "Christian", pin: "56789012", profile_key: nil}
]
