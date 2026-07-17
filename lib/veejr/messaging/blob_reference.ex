defmodule Veejr.Messaging.BlobReference do
  use Ecto.Schema

  schema "blob_references" do
    belongs_to :blob, Veejr.Messaging.Blob
    field :batch_id, :string

    timestamps(type: :utc_datetime)
  end
end
