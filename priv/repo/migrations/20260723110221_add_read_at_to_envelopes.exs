defmodule Veejr.Repo.Migrations.AddReadAtToEnvelopes do
  use Ecto.Migration

  def up do
    alter table(:envelopes) do
      add :read_at, :utc_datetime
    end

    execute("UPDATE envelopes SET read_at = CURRENT_TIMESTAMP")
  end

  def down do
    alter table(:envelopes) do
      remove :read_at
    end
  end
end
