defmodule Veejr.Repo.Migrations.AddFederationSupport do
  use Ecto.Migration

  def change do
    # Remote people are ordinary user rows with `host` set to their
    # instance's authority (e.g. "veejr.example.com", "localhost:4001").
    # Local users have host = NULL. This lets friendships, groups, and
    # envelopes reference remote users with zero schema changes elsewhere.
    alter table(:users) do
      add :host, :string
    end

    drop unique_index(:users, [:username])

    create unique_index(:users, ["username", "COALESCE(host, '')"],
             name: :users_username_host_index
           )
  end
end
