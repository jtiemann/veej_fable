defmodule Veejr.Repo.Migrations.AddAndroidPushTokens do
  use Ecto.Migration

  def change do
    alter table(:api_device_sessions) do
      add :push_token, :string
      add :push_token_updated_at, :utc_datetime
    end

    create unique_index(:api_device_sessions, [:push_token], where: "push_token IS NOT NULL")

    create table(:push_deliveries) do
      add :notification_id, references(:notifications, on_delete: :delete_all), null: false
      add :push_subscription_id, references(:push_subscriptions, on_delete: :delete_all)
      add :api_device_session_id, references(:api_device_sessions, on_delete: :delete_all)
      add :channel, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime, null: false
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:push_deliveries, [:next_attempt_at])
    create unique_index(:push_deliveries, [:notification_id, :push_subscription_id])
    create unique_index(:push_deliveries, [:notification_id, :api_device_session_id])
  end
end
