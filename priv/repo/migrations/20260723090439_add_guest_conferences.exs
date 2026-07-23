defmodule Veejr.Repo.Migrations.AddGuestConferences do
  use Ecto.Migration

  def change do
    create table(:guest_conferences) do
      add :public_id, :string, null: false
      add :token_hash, :string, null: false
      add :invited_email, :string, null: false
      add :display_name, :string
      add :public_key, :string
      add :state, :string, null: false, default: "sent"
      add :expires_at, :utc_datetime, null: false
      add :admitted_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :joined_at, :utc_datetime
      add :host_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:guest_conferences, [:public_id])
    create unique_index(:guest_conferences, [:token_hash])
    create index(:guest_conferences, [:host_id, :state])
    create index(:guest_conferences, [:expires_at])

    create table(:guest_calls) do
      add :public_id, :string, null: false
      add :state, :string, null: false, default: "ringing"
      add :host_id, references(:users, on_delete: :delete_all), null: false

      add :guest_conference_id,
          references(:guest_conferences, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:guest_calls, [:public_id])
    create unique_index(:guest_calls, [:guest_conference_id])
    create index(:guest_calls, [:host_id])
  end
end
