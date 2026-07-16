defmodule Veejr.Repo.Migrations.AddPeerBlocking do
  use Ecto.Migration

  def change do
    alter table(:peers) do
      add :blocked_at, :utc_datetime
      add :blocked_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:peers, [:blocked_at])
    create index(:peers, [:blocked_by_id])
  end
end
