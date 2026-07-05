defmodule Veejr.Repo.Migrations.AddProfileAndKeysToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :string
      add :display_name, :string
      # E2E crypto material. The server only ever stores:
      #  - the public key (needed by friends to encrypt to this user)
      #  - the secret key encrypted client-side with a passphrase-derived key
      add :public_key, :string
      add :enc_secret_key, :string
      add :key_salt, :string
      add :key_nonce, :string
    end

    create unique_index(:users, [:username])
  end
end
