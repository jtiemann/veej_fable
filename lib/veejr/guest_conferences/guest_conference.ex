defmodule Veejr.GuestConferences.GuestConference do
  use Ecto.Schema
  import Ecto.Changeset

  schema "guest_conferences" do
    field :public_id, :string
    field :token_hash, :string
    field :invited_email, :string
    field :display_name, :string
    field :public_key, :string
    field :state, :string, default: "sent"
    field :expires_at, :utc_datetime
    field :admitted_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :joined_at, :utc_datetime

    belongs_to :host, Veejr.Accounts.User
    has_one :call, Veejr.GuestConferences.GuestCall

    timestamps(type: :utc_datetime)
  end

  def invitation_changeset(conference, attrs) do
    conference
    |> cast(attrs, [:invited_email])
    |> update_change(:invited_email, &normalize_email/1)
    |> validate_required([:invited_email])
    |> validate_format(:invited_email, ~r/^[^\s]+@[^\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:invited_email, max: 160)
  end

  def create_changeset(conference, attrs) do
    conference
    |> cast(attrs, [:public_id, :token_hash, :invited_email, :expires_at, :host_id])
    |> update_change(:invited_email, &normalize_email/1)
    |> validate_required([:public_id, :token_hash, :invited_email, :expires_at, :host_id])
    |> validate_format(:invited_email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:public_id)
    |> unique_constraint(:token_hash)
  end

  def waiting_changeset(conference, attrs) do
    conference
    |> cast(attrs, [:display_name, :public_key])
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:display_name, :public_key])
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_length(:public_key, min: 40, max: 60)
    |> validate_change(:public_key, fn :public_key, value ->
      case Base.decode64(value) do
        {:ok, bytes} when byte_size(bytes) == 32 -> []
        _ -> [public_key: "is not a valid guest identity"]
      end
    end)
  end

  defp normalize_email(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end
end
