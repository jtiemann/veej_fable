defmodule Veejr.Repo.Migrations.AddMessageEditAndExpiryFields do
  use Ecto.Migration

  def change do
    alter table(:envelopes) do
      add :edited_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :max_displays, :integer
      add :display_count, :integer, null: false, default: 0
    end

    create index(:envelopes, [:expires_at])
  end
end
