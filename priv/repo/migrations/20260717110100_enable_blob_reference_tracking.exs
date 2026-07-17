defmodule Veejr.Repo.Migrations.EnableBlobReferenceTracking do
  use Ecto.Migration

  def change do
    alter table(:blobs) do
      add :reference_tracking, :boolean, null: false, default: false
    end

    create index(:blobs, [:reference_tracking, :inserted_at])
  end
end
