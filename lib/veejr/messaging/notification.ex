defmodule Veejr.Messaging.Notification do
  use Ecto.Schema

  @states ~w(pending accepted declined)

  schema "notifications" do
    field :state, :string, default: "pending"

    belongs_to :envelope, Veejr.Messaging.Envelope
    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
end
