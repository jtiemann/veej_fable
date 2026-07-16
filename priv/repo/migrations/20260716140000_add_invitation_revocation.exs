defmodule Veejr.Repo.Migrations.AddInvitationRevocation do
  use Ecto.Migration

  def change do
    alter table(:account_invitations) do
      add :revoked_at, :utc_datetime
      add :revoked_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:account_invitations, [:revoked_at])
    create index(:account_invitations, [:revoked_by_id])
  end
end
