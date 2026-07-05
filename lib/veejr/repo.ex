defmodule Veejr.Repo do
  use Ecto.Repo,
    otp_app: :veejr,
    adapter: Ecto.Adapters.SQLite3
end
