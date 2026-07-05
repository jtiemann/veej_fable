defmodule Veejr.Repo.Migrations.AddKeyRotationSupport do
  use Ecto.Migration

  def up do
    alter table(:envelopes) do
      # The sender's public key AT SEND TIME. Decryption must always use the
      # key the envelope was actually sealed with — senders may rotate later.
      add :sender_public_key, :string
      # True once the recipient re-encrypted this envelope to their own
      # (new) key during rotation; decryption then uses their current key.
      add :resealed, :boolean, null: false, default: false
    end

    # Pre-rotation rows: the sender's current key IS the key at send time.
    execute """
    UPDATE envelopes SET sender_public_key =
      (SELECT public_key FROM users WHERE users.id = envelopes.sender_id)
    """

    alter table(:users) do
      # A remote contact's announced-but-unconfirmed new key. A human must
      # accept it on the Friends page before it replaces the pinned key.
      add :pending_public_key, :string
    end
  end

  def down do
    alter table(:envelopes) do
      remove :sender_public_key
      remove :resealed
    end

    alter table(:users) do
      remove :pending_public_key
    end
  end
end
