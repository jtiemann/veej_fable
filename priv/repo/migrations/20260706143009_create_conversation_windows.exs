defmodule Veejr.Repo.Migrations.CreateConversationWindows do
  use Ecto.Migration

  def change do
    # A rolling "active conversation" window: while `active_until` is in the
    # future, messages from `peer` to `user` are auto-accepted (shown in the
    # chat without a fresh request). Re-upped on every send or receive.
    create table(:conversation_windows) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :peer_id, references(:users, on_delete: :delete_all), null: false
      add :active_until, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_windows, [:user_id, :peer_id])
  end
end
