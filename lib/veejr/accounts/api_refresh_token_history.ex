defmodule Veejr.Accounts.ApiRefreshTokenHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_refresh_token_histories" do
    field :token_hash, :binary, redact: true
    belongs_to :api_device_session, Veejr.Accounts.ApiDeviceSession

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(history, session, token_hash) do
    history
    |> change(api_device_session_id: session.id, token_hash: token_hash)
    |> validate_required([:api_device_session_id, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
