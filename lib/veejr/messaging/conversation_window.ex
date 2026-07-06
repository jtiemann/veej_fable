defmodule Veejr.Messaging.ConversationWindow do
  @moduledoc """
  A rolling "active conversation" window for one direction: while
  `active_until` is in the future, messages from `peer` to `user` are
  auto-accepted and appear in the chat without a fresh request. The window
  is re-upped to 5 minutes whenever `user` sends to `peer` or receives an
  (auto-accepted) message from `peer`.
  """
  use Ecto.Schema

  schema "conversation_windows" do
    belongs_to :user, Veejr.Accounts.User
    belongs_to :peer, Veejr.Accounts.User
    field :active_until, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
