defmodule Veejr.Messaging.Blob do
  use Ecto.Schema

  schema "blobs" do
    field :public_id, :string
    field :size, :integer
    field :path, :string

    belongs_to :owner, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
