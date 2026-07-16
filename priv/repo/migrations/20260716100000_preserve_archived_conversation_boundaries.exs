defmodule Veejr.Repo.Migrations.PreserveArchivedConversationBoundaries do
  use Ecto.Migration

  def up do
    alter table(:conversation_archives) do
      add :participant_key, :string
      add :envelope_ids, :text
      add :started_at, :utc_datetime
      add :archived, :boolean, null: false, default: true
    end

    execute """
    UPDATE conversation_archives
    SET participant_key = conversation_key,
        envelope_ids = '[]',
        started_at = inserted_at
    """

    create index(:conversation_archives, [:user_id, :participant_key])
  end

  def down do
    drop index(:conversation_archives, [:user_id, :participant_key])

    alter table(:conversation_archives) do
      remove :participant_key
      remove :envelope_ids
      remove :started_at
      remove :archived
    end
  end
end
