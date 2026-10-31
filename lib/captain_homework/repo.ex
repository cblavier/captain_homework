defmodule CaptainHomework.Repo do
  use Ecto.Repo,
    otp_app: :captain_homework,
    adapter: Ecto.Adapters.SQLite3
end
