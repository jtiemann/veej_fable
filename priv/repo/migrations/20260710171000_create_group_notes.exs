defmodule Veejr.Repo.Migrations.CreateGroupNotes do
  use Ecto.Migration

  def change do
    create table(:group_notes) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :body, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_notes, [:owner_id, :group_id])
  end
end
