defmodule Veejr.Repo.Migrations.AddHardeningTables do
  use Ecto.Migration

  def change do
    # This instance's own key material: an Ed25519 signing pair for
    # federation requests and a P-256 pair for Web Push VAPID. Secret keys
    # live in the DB — the server signs with them, so DB access already
    # implies signing ability.
    create table(:instance_credentials) do
      add :kind, :string, null: false
      add :public_key, :string, null: false
      add :secret_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instance_credentials, [:kind])

    # Signing keys of other instances, pinned on first contact.
    create table(:peers) do
      add :authority, :string, null: false
      add :public_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:peers, [:authority])

    # Federation deliveries awaiting retry (recipient instance unreachable).
    create table(:outbound_deliveries) do
      add :authority, :string, null: false
      add :path, :string, null: false
      add :payload, :text, null: false
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime, null: false
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:outbound_deliveries, [:next_attempt_at])

    # Browser push subscriptions (one per device/browser).
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :string, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
