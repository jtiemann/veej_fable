defmodule Veejr.Repo.Migrations.CreateAccountMoves do
  use Ecto.Migration

  def change do
    create table(:account_moves) do
      add :public_id, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :initiated_by_id, references(:users, on_delete: :nothing), null: false
      add :username, :string, null: false
      add :target_host, :string, null: false
      add :instance_name, :string, null: false
      add :instance_mode, :string, null: false, default: "personal"
      add :status, :string, null: false
      add :export_path, :string
      add :export_sha256, :string
      add :export_size, :integer
      add :expected_envelopes, :integer, null: false, default: 0
      add :expected_blobs, :integer, null: false, default: 0
      add :expected_friends, :integer, null: false, default: 0
      add :receipt, :map
      add :error, :text
      add :cutover_at, :utc_datetime
      add :verified_at, :utc_datetime
      add :finalized_at, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_moves, [:public_id])

    create unique_index(:account_moves, [:target_host],
             where: "status != 'cancelled'",
             name: :account_moves_active_target_host_index
           )

    create index(:account_moves, [:status, :inserted_at])
    create index(:account_moves, [:user_id])
    create index(:account_moves, [:initiated_by_id])
  end
end
