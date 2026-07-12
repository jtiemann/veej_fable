defmodule Veejr.Accounts.ApiIdempotencyKey do
  use Ecto.Schema

  schema "api_idempotency_keys" do
    field :operation, :string
    field :key, :string
    field :request_hash, :binary
    field :response, :map

    belongs_to :api_device_session, Veejr.Accounts.ApiDeviceSession

    timestamps(type: :utc_datetime)
  end
end
