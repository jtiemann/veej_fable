defmodule Veejr.Social.GroupNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_notes" do
    belongs_to :owner, Veejr.Accounts.User
    belongs_to :group, Veejr.Social.Group
    field :body, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(group_note, attrs) do
    group_note
    |> cast(attrs, [:owner_id, :group_id, :body])
    |> validate_required([:owner_id, :group_id])
    |> validate_length(:body, max: 4_000)
    |> unique_constraint([:owner_id, :group_id])
  end
end
