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

    belongs_to :sender, Veejr.Accounts.User
    belongs_to :recipient, Veejr.Accounts.User
    has_one :notification, Veejr.Messaging.Notification

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [:recipient_id, :kind, :ciphertext, :nonce])
    |> validate_required([:recipient_id, :kind, :ciphertext, :nonce])
    |> validate_inclusion(:kind, @kinds)
    # ~256 KB of base64 keeps envelope bodies light; bulk data goes in blobs.
    |> validate_length(:ciphertext, max: 350_000)
    |> unique_constraint(:public_id)
  end
end
