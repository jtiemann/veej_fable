defmodule Veejr.Repo.Migrations.CreateContactNotes do
  use Ecto.Migration

  def change do
    create table(:contact_notes) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :contact_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contact_notes, [:owner_id, :contact_id])
    create index(:contact_notes, [:contact_id])
  end
end
