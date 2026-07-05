defmodule Veejr.Social.GroupMember do
  use Ecto.Schema

  schema "group_members" do
    belongs_to :group, Veejr.Social.Group
    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
