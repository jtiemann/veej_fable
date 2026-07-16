defmodule Veejr.Repo.Migrations.CreateAdminAuditEvents do
  use Ecto.Migration

  def up do
    create table(:admin_audit_events) do
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :integer, null: false
      add :details, :map, null: false, default: %{}
      add :actor_user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:admin_audit_events, [:inserted_at])
    create index(:admin_audit_events, [:actor_user_id])
    create index(:admin_audit_events, [:target_type, :target_id])

    execute """
    CREATE TRIGGER admin_audit_events_immutable_update
    BEFORE UPDATE ON admin_audit_events
    BEGIN
      SELECT RAISE(ABORT, 'admin audit events cannot be changed');
    END
    """

    execute """
    CREATE TRIGGER admin_audit_events_immutable_delete
    BEFORE DELETE ON admin_audit_events
    BEGIN
      SELECT RAISE(ABORT, 'admin audit events cannot be removed');
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS admin_audit_events_immutable_delete"
    execute "DROP TRIGGER IF EXISTS admin_audit_events_immutable_update"
    drop table(:admin_audit_events)
  end
end
