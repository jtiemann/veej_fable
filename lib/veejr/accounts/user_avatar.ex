defmodule Veejr.Accounts.UserAvatar do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_avatars" do
    field :image, :binary, redact: true
    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(avatar, attrs) do
    avatar
    |> cast(attrs, [:user_id, :image])
    |> validate_required([:user_id, :image])
    |> unique_constraint(:user_id)
  end
end
