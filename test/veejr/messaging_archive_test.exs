defmodule Veejr.MessagingArchiveTest do
  use Veejr.DataCase

  alias Veejr.Messaging
  import Veejr.AccountsFixtures

  test "archives and unarchives a conversation for one user" do
    user = user_fixture()
    participants = ["@alice@example.test", "@bob@example.test"]
    key = Messaging.conversation_key(participants)
    started_at = ~U[2026-07-01 09:30:00Z]

    assert {:ok, archive} =
             Messaging.archive_conversation(user, key, participants, ["message-1"], started_at)

    archive_key = archive.conversation_key
    assert archive_key != key
    assert archive_key =~ "20260701T093000"

    assert [
             %{
               key: ^archive_key,
               participant_key: ^key,
               participants: ^participants,
               started_at: ^started_at
             }
           ] =
             Messaging.list_archived_conversations(user)

    assert :ok = Messaging.unarchive_conversation(user, archive_key)
    assert Messaging.list_archived_conversations(user) == []
  end

  test "does not archive a conversation with a mismatched key" do
    user = user_fixture()

    assert {:error, :invalid_conversation} =
             Messaging.archive_conversation(
               user,
               "not-the-key",
               ["@alice@example.test"],
               ["message-1"],
               DateTime.utc_now(:second)
             )
  end

  test "unarchived history stays separate from a newer conversation" do
    user = user_fixture()

    first = self_message(user, "first")
    participants = ["notes to yourself"]
    current_key = Messaging.conversation_key(participants)

    assert {:ok, archive} =
             Messaging.archive_conversation(
               user,
               current_key,
               participants,
               [first.public_id],
               first.inserted_at
             )

    second = self_message(user, "second")
    history = Messaging.list_history(user, kind: "message")

    assert [%{key: ^current_key, envelope_ids: [second_id]}] =
             Messaging.conversation_threads(user, history)

    assert second_id == second.public_id
    assert :ok = Messaging.unarchive_conversation(user, archive.conversation_key)

    threads = Messaging.conversation_threads(user, history)
    assert Enum.map(threads, & &1.key) |> Enum.uniq() |> length() == 2

    assert Enum.sort(Enum.flat_map(threads, & &1.envelope_ids)) ==
             Enum.sort([first.public_id, second.public_id])
  end

  defp self_message(user, ciphertext) do
    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => user.id, "ciphertext" => ciphertext, "nonce" => "nonce"}
      ])

    Veejr.Repo.get_by!(Veejr.Messaging.Envelope,
      batch_id: batch_id,
      recipient_id: user.id
    )
  end
end
