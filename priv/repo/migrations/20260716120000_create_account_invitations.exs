defmodule Veejr.Repo.Migrations.CreateAccountInvitations do
  use Ecto.Migration

  def change do
    create table(:account_invitations) do
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :seen_at, :utc_datetime
      add :inviter_id, references(:users, on_delete: :delete_all), null: false
      add :accepted_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_invitations, [:token_hash])
    create index(:account_invitations, [:inviter_id, :seen_at])
    create index(:account_invitations, [:accepted_by_id])
  end
end
