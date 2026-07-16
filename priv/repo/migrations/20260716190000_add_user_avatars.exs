defmodule Veejr.Repo.Migrations.AddUserAvatars do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :has_avatar, :boolean, null: false, default: false
      add :avatar_version, :integer, null: false, default: 0
    end

    create table(:user_avatars) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :image, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_avatars, [:user_id])
  end
end
