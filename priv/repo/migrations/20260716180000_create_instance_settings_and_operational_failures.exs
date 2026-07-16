defmodule Veejr.Repo.Migrations.CreateInstanceSettingsAndOperationalFailures do
  use Ecto.Migration

  def up do
    create table(:instance_settings, primary_key: false) do
      add :id, :integer, primary_key: true, null: false
      add :name, :string
      add :description, :string
      add :registration_policy, :string, null: false, default: "mode_default"
      add :invitation_lifetime_hours, :integer, null: false, default: 168
      add :max_upload_bytes, :integer, null: false, default: 26_214_400
      add :storage_quota_bytes, :integer
      add :default_retention_hours, :integer
      add :mail_from_name, :string
      add :mail_from_address, :string

      timestamps(type: :utc_datetime)
    end

    execute """
    INSERT INTO instance_settings (
      id, registration_policy, invitation_lifetime_hours, max_upload_bytes,
      inserted_at, updated_at
    ) VALUES (1, 'mode_default', 168, 26214400, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """

    execute """
    CREATE TRIGGER instance_settings_singleton_insert
    BEFORE INSERT ON instance_settings
    WHEN NEW.id != 1 OR EXISTS (SELECT 1 FROM instance_settings WHERE id = 1)
    BEGIN
      SELECT RAISE(ABORT, 'only one instance settings row is allowed');
    END
    """

    execute """
    CREATE TRIGGER instance_settings_protect_delete
    BEFORE DELETE ON instance_settings
    BEGIN
      SELECT RAISE(ABORT, 'instance settings cannot be removed');
    END
    """

    create table(:operational_failures) do
      add :channel, :string, null: false
      add :operation, :string, null: false
      add :error, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:operational_failures, [:channel, :inserted_at])
  end

  def down do
    drop table(:operational_failures)
    execute "DROP TRIGGER IF EXISTS instance_settings_protect_delete"
    execute "DROP TRIGGER IF EXISTS instance_settings_singleton_insert"
    drop table(:instance_settings)
  end
end
