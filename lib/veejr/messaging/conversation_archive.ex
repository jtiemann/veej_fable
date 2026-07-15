defmodule Veejr.Messaging.ConversationArchive do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_archives" do
    field :conversation_key, :string
    field :participants, :string

    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(archive, attrs) do
    archive
    |> cast(attrs, [:user_id, :conversation_key, :participants])
    |> validate_required([:user_id, :conversation_key, :participants])
    |> unique_constraint([:user_id, :conversation_key])
  end
end
