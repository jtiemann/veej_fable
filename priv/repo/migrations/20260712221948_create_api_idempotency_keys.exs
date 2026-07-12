defmodule Veejr.Repo.Migrations.CreateApiIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:api_idempotency_keys) do
      add :api_device_session_id, references(:api_device_sessions, on_delete: :delete_all),
        null: false

      add :operation, :string, null: false
      add :key, :string, null: false
      add :request_hash, :binary, null: false, size: 32
      add :response, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_idempotency_keys, [:api_device_session_id, :operation, :key])
  end
end
