defmodule Veejr.Repo.Migrations.CreateApiDeviceSessions do
  use Ecto.Migration

  def change do
    create table(:api_device_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :device_name, :string, null: false
      add :platform, :string, null: false
      add :app_version, :string
      add :access_token_hash, :binary, null: false, size: 32
      add :access_expires_at, :utc_datetime, null: false
      add :refresh_token_hash, :binary, null: false, size: 32
      add :refresh_expires_at, :utc_datetime, null: false
      add :authenticated_at, :utc_datetime, null: false
      add :last_used_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_device_sessions, [:user_id])
    create unique_index(:api_device_sessions, [:access_token_hash])
    create unique_index(:api_device_sessions, [:refresh_token_hash])
  end
end
