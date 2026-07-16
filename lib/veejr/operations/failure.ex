defmodule Veejr.Operations.Failure do
  use Ecto.Schema

  schema "operational_failures" do
    field :channel, :string
    field :operation, :string
    field :error, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
