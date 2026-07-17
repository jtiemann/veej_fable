defmodule Veejr.Repo.Migrations.CreateBlobReferences do
  use Ecto.Migration

  def change do
    create table(:blob_references) do
      add :blob_id, references(:blobs, on_delete: :delete_all), null: false
      add :batch_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:blob_references, [:blob_id, :batch_id])
    create index(:blob_references, [:batch_id])
  end
end
