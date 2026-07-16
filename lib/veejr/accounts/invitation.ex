defmodule Veejr.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "account_invitations" do
    field :token_hash, :string
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :seen_at, :utc_datetime

    belongs_to :inviter, Veejr.Accounts.User
    belongs_to :accepted_by, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:token_hash, :expires_at, :inviter_id])
    |> validate_required([:token_hash, :expires_at, :inviter_id])
    |> unique_constraint(:token_hash)
  end
end
