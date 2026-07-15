defmodule Veejr.MessagingArchiveTest do
  use Veejr.DataCase

  alias Veejr.Messaging
  import Veejr.AccountsFixtures

  test "archives and unarchives a conversation for one user" do
    user = user_fixture()
    participants = ["@alice@example.test", "@bob@example.test"]
    key = Messaging.conversation_key(participants)

    assert {:ok, _archive} = Messaging.archive_conversation(user, key, participants)
    assert MapSet.member?(Messaging.archived_conversation_keys(user), key)

    assert [%{key: ^key, participants: ^participants}] =
             Messaging.list_archived_conversations(user)

    assert :ok = Messaging.unarchive_conversation(user, key)
    refute MapSet.member?(Messaging.archived_conversation_keys(user), key)
  end

  test "does not archive a conversation with a mismatched key" do
    user = user_fixture()

    assert {:error, :invalid_conversation} =
             Messaging.archive_conversation(user, "not-the-key", ["@alice@example.test"])
  end
end
