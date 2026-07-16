defmodule Veejr.MessagingSendTest do
  use Veejr.DataCase

  alias Veejr.Messaging
  import Veejr.AccountsFixtures

  test "rejects duplicate copies for the same recipient" do
    user = user_fixture()

    envelopes = [
      %{"recipient_id" => to_string(user.id), "ciphertext" => "first", "nonce" => "nonce-1"},
      %{"recipient_id" => user.id, "ciphertext" => "second", "nonce" => "nonce-2"}
    ]

    assert {:error, :duplicate_recipients} =
             Messaging.send_batch(user, "message", envelopes)

    assert Messaging.list_history(user) == []
  end
end
