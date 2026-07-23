defmodule Veejr.GuestConferences.GuestCall do
  use Ecto.Schema

  schema "guest_calls" do
    field :public_id, :string
    field :state, :string, default: "ringing"

    belongs_to :host, Veejr.Accounts.User
    belongs_to :guest_conference, Veejr.GuestConferences.GuestConference

    timestamps(type: :utc_datetime)
  end
end
