defmodule Veejr.Repo.Migrations.AddAccountSuspension do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :suspended_at, :utc_datetime
      add :suspended_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:users, [:suspended_at])
    create index(:users, [:suspended_by_id])

    execute """
    CREATE TRIGGER users_protect_instance_admin_suspension
    BEFORE UPDATE OF suspended_at ON users
    WHEN NEW.suspended_at IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM instance_administration
        WHERE admin_user_id = NEW.id
      )
    BEGIN
      SELECT RAISE(ABORT, 'instance administrator cannot be suspended');
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS users_protect_instance_admin_suspension"

    drop index(:users, [:suspended_by_id])
    drop index(:users, [:suspended_at])

    alter table(:users) do
      remove :suspended_by_id
      remove :suspended_at
    end
  end
end
