defmodule Veejr.Social.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    belongs_to :owner, Veejr.Accounts.User
    field :name, :string

    has_many :memberships, Veejr.Social.GroupMember
    many_to_many :members, Veejr.Accounts.User, join_through: Veejr.Social.GroupMember

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint([:owner_id, :name], message: "you already have a group with this name")
  end
end
