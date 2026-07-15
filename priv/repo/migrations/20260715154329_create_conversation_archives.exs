defmodule Veejr.Repo.Migrations.CreateConversationArchives do
  use Ecto.Migration

  def change do
    create table(:conversation_archives) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :conversation_key, :string, null: false
      add :participants, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_archives, [:user_id, :conversation_key])
    create index(:conversation_archives, [:user_id, :updated_at])
  end
end
