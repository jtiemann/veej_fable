defmodule Veejr.Repo.Migrations.CreateMessagingTables do
  use Ecto.Migration

  def change do
    # One envelope per (sender, recipient) pair. The payload is encrypted
    # client-side to that recipient's public key; the server never stores
    # plaintext. Senders also write a copy encrypted to themselves
    # (recipient_id == sender_id) so their own history stays readable.
    create table(:envelopes) do
      add :public_id, :string, null: false
      add :batch_id, :string, null: false
      add :sender_id, references(:users, on_delete: :delete_all), null: false
      add :recipient_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :ciphertext, :text, null: false
      add :nonce, :string, null: false
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:envelopes, [:public_id])
    create index(:envelopes, [:recipient_id])
    create index(:envelopes, [:sender_id, :batch_id])

    # Pull-based delivery: recipients are notified that something awaits and
    # must accept before the ciphertext is served to them.
    create table(:notifications) do
      add :envelope_id, references(:envelopes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id, :state])
    create unique_index(:notifications, [:envelope_id])

    # Attachments, encrypted client-side before upload. The symmetric key
    # travels inside the message envelope, never alongside the blob.
    create table(:blobs) do
      add :public_id, :string, null: false
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :size, :integer, null: false
      add :path, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:blobs, [:public_id])
  end
end
