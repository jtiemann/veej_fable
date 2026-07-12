defmodule Veejr.Repo.Migrations.CreateApiRefreshTokenHistories do
  use Ecto.Migration

  def change do
    create table(:api_refresh_token_histories) do
      add :api_device_session_id,
          references(:api_device_sessions, on_delete: :delete_all),
          null: false

      add :token_hash, :binary, null: false, size: 32

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:api_refresh_token_histories, [:api_device_session_id])
    create unique_index(:api_refresh_token_histories, [:token_hash])
  end
end
