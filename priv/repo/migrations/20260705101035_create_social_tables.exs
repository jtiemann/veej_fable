defmodule Veejr.Repo.Migrations.CreateSocialTables do
  use Ecto.Migration

  def change do
    create table(:friendships) do
      add :requester_id, references(:users, on_delete: :delete_all), null: false
      add :addressee_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:friendships, [:requester_id, :addressee_id])
    create index(:friendships, [:addressee_id])

    # Groups are personal: each user organizes their own friends into groups;
    # a friend can appear in any number of the owner's groups.
    create table(:groups) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:owner_id, :name])

    create table(:group_members) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_members, [:group_id, :user_id])
  end
end
