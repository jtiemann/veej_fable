defmodule Veejr.Messaging.ConversationArchive do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_archives" do
    field :conversation_key, :string
    field :participant_key, :string
    field :participants, :string
    field :envelope_ids, :string
    field :started_at, :utc_datetime
    field :archived, :boolean, default: true

    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(archive, attrs) do
    archive
    |> cast(attrs, [
      :user_id,
      :conversation_key,
      :participant_key,
      :participants,
      :envelope_ids,
      :started_at,
      :archived
    ])
    |> validate_required([
      :user_id,
      :conversation_key,
      :participant_key,
      :participants,
      :envelope_ids,
      :started_at,
      :archived
    ])
    |> unique_constraint([:user_id, :conversation_key])
  end
end
