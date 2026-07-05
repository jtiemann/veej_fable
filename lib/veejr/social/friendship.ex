defmodule Veejr.Social.Friendship do
  use Ecto.Schema
  import Ecto.Changeset

  schema "friendships" do
    belongs_to :requester, Veejr.Accounts.User
    belongs_to :addressee, Veejr.Accounts.User
    field :status, :string, default: "pending"

    timestamps(type: :utc_datetime)
  end

  def changeset(friendship, attrs) do
    friendship
    |> cast(attrs, [:requester_id, :addressee_id, :status])
    |> validate_required([:requester_id, :addressee_id, :status])
    |> validate_inclusion(:status, ~w(pending accepted))
    |> check_not_self()
    |> unique_constraint([:requester_id, :addressee_id])
  end

  defp check_not_self(changeset) do
    if get_field(changeset, :requester_id) == get_field(changeset, :addressee_id) do
      add_error(changeset, :addressee_id, "cannot befriend yourself")
    else
      changeset
    end
  end
end
