defmodule Veejr.Messaging.Envelope do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(message location note self_note)

  schema "envelopes" do
    field :public_id, :string
    field :batch_id, :string
    field :kind, :string
    field :ciphertext, :string
    field :nonce, :string
    field :delivered_at, :utc_datetime
    field :edited_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :max_displays, :integer
    field :display_count, :integer, default: 0
    # the sender's public key at send time — decryption survives rotation
    field :sender_public_key, :string
    # re-encrypted to the recipient's own key during their rotation
    field :resealed, :boolean, default: false
    # conversation identity, materialized at insert so threads are queryable:
    # the stable key of `participants` (a JSON-encoded sorted handle list),
    # rewritten to an instance key when the viewer archives the conversation
    field :thread_key, :string
    field :participants, :string
    # opaque, client-computed idempotency token for imported self-notes; NULL for
    # everything else. Unique per recipient so re-importing skips existing notes.
    field :dedup_key, :string

    belongs_to :sender, Veejr.Accounts.User
    belongs_to :recipient, Veejr.Accounts.User
    has_one :notification, Veejr.Messaging.Notification

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :recipient_id,
      :kind,
      :ciphertext,
      :nonce,
      :expires_at,
      :max_displays,
      :dedup_key
    ])
    |> validate_required([:recipient_id, :kind, :ciphertext, :nonce])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:max_displays, greater_than: 0, less_than_or_equal_to: 100)
    # ~256 KB of base64 keeps envelope bodies light; bulk data goes in blobs.
    |> validate_length(:ciphertext, max: 350_000)
    |> unique_constraint(:public_id)
    |> unique_constraint([:batch_id, :recipient_id])
    |> unique_constraint([:recipient_id, :dedup_key])
  end
end
