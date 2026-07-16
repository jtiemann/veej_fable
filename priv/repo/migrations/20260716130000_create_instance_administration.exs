defmodule Veejr.Repo.Migrations.CreateInstanceAdministration do
  use Ecto.Migration

  def up do
    create table(:instance_administration, primary_key: false) do
      add :id, :integer, primary_key: true, null: false
      add :admin_user_id, references(:users, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instance_administration, [:admin_user_id])

    execute """
    CREATE TRIGGER instance_administration_singleton_insert
    BEFORE INSERT ON instance_administration
    WHEN NEW.id != 1
    BEGIN
      SELECT RAISE(ABORT, 'only one instance administrator assignment is allowed');
    END
    """

    execute """
    INSERT INTO instance_administration (id, admin_user_id, inserted_at, updated_at)
    SELECT 1, id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM users
    WHERE host IS NULL
    ORDER BY inserted_at ASC, id ASC
    LIMIT 1
    """

    execute """
    CREATE TRIGGER users_assign_first_local_instance_administrator
    AFTER INSERT ON users
    WHEN NEW.host IS NULL
      AND NOT EXISTS (SELECT 1 FROM instance_administration WHERE id = 1)
    BEGIN
      INSERT INTO instance_administration (id, admin_user_id, inserted_at, updated_at)
      VALUES (1, NEW.id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
    END
    """

    execute """
    CREATE TRIGGER instance_administration_immutable_update
    BEFORE UPDATE ON instance_administration
    BEGIN
      SELECT RAISE(ABORT, 'instance administrator cannot be changed');
    END
    """

    execute """
    CREATE TRIGGER instance_administration_immutable_delete
    BEFORE DELETE ON instance_administration
    BEGIN
      SELECT RAISE(ABORT, 'instance administrator assignment cannot be removed');
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS users_assign_first_local_instance_administrator"
    execute "DROP TRIGGER IF EXISTS instance_administration_immutable_delete"
    execute "DROP TRIGGER IF EXISTS instance_administration_immutable_update"
    execute "DROP TRIGGER IF EXISTS instance_administration_singleton_insert"
    drop table(:instance_administration)
  end
end
