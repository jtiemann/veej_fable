defmodule Veejr.Repo.Migrations.CreateCalls do
  use Ecto.Migration

  def change do
    create table(:calls) do
      add :public_id, :string, null: false
      add :caller_id, references(:users, on_delete: :delete_all), null: false
      add :callee_id, references(:users, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "ringing"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calls, [:public_id])
    create index(:calls, [:callee_id, :state])
  end
end
