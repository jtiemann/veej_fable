defmodule Veejr.Messaging.Envelope do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(message location note)

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

    belongs_to :sender, Veejr.Accounts.User
    belongs_to :recipient, Veejr.Accounts.User
    has_one :notification, Veejr.Messaging.Notification

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [:recipient_id, :kind, :ciphertext, :nonce, :expires_at, :max_displays])
    |> validate_required([:recipient_id, :kind, :ciphertext, :nonce])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:max_displays, greater_than: 0, less_than_or_equal_to: 100)
    # ~256 KB of base64 keeps envelope bodies light; bulk data goes in blobs.
    |> validate_length(:ciphertext, max: 350_000)
    |> unique_constraint(:public_id)
    |> unique_constraint([:batch_id, :recipient_id])
  end
end
