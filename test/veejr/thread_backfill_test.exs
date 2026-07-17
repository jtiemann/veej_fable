defmodule Veejr.ThreadBackfillTest do
  use Veejr.DataCase

  alias Veejr.Messaging
  alias Veejr.Messaging.{ConversationArchive, Envelope, ThreadBackfill}
  import Veejr.AccountsFixtures

  test "replays the historical grouping and archive claims" do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})

    bob_key = Messaging.conversation_key(["@bob"])
    alice_key = Messaging.conversation_key(["@alice"])
    notes_key = Messaging.conversation_key(["notes to yourself"])

    # Legacy-shaped rows: no thread fields, as before the migration.
    raw_envelope("recv-old", "recv-old", bob, alice, ~U[2026-01-01 10:00:00Z])

    batch = "sent-batch"
    raw_envelope("sent-self", batch, alice, alice, ~U[2026-02-01 10:00:00Z])
    raw_envelope("sent-copy", batch, alice, bob, ~U[2026-02-01 10:00:00Z])

    raw_envelope("notes-1", "notes-batch", alice, alice, ~U[2026-03-01 10:00:00Z])

    # A legacy archive whose key still equals the participant key, recorded
    # between the old and new bob-thread messages: it must claim only the
    # older message, under a freshly minted instance key.
    legacy_archive =
      Repo.insert!(%ConversationArchive{
        user_id: alice.id,
        conversation_key: bob_key,
        participant_key: bob_key,
        participants: Jason.encode!(["@bob"]),
        envelope_ids: "[]",
        started_at: ~U[2026-01-01 10:00:00Z],
        archived: true,
        inserted_at: ~U[2026-01-15 10:00:00Z],
        updated_at: ~U[2026-01-15 10:00:00Z]
      })

    # A newer archive with explicit envelope ids and an instance key.
    explicit_archive =
      Repo.insert!(%ConversationArchive{
        user_id: alice.id,
        conversation_key: "#{notes_key}-20260301T100000-abc123",
        participant_key: notes_key,
        participants: Jason.encode!(["notes to yourself"]),
        envelope_ids: Jason.encode!(["notes-1"]),
        started_at: ~U[2026-03-01 10:00:00Z],
        archived: true,
        inserted_at: ~U[2026-03-02 10:00:00Z],
        updated_at: ~U[2026-03-02 10:00:00Z]
      })

    assert :ok = ThreadBackfill.run(Repo)

    # the legacy archive was migrated to a distinct instance key…
    migrated = Repo.get!(ConversationArchive, legacy_archive.id)
    assert migrated.conversation_key != bob_key
    assert migrated.conversation_key =~ bob_key

    # …claiming only the pre-archive message; the newer sent message stays
    # in the current bob thread
    assert thread_key("recv-old") == migrated.conversation_key
    assert thread_key("sent-self") == bob_key
    assert participants("sent-self") == ["@bob"]

    # bob's received copy threads under alice, from bob's point of view
    assert thread_key("sent-copy") == alice_key
    assert participants("sent-copy") == ["@alice"]

    # the explicit archive claimed its envelope under its existing key
    assert thread_key("notes-1") == explicit_archive.conversation_key
    assert participants("notes-1") == ["notes to yourself"]

    # unclaimed received rows carry the sender-handle participants
    assert participants("recv-old") == ["@bob"]
  end

  defp raw_envelope(public_id, batch_id, sender, recipient, inserted_at) do
    Repo.insert!(%Envelope{
      public_id: public_id,
      batch_id: batch_id,
      sender_id: sender.id,
      recipient_id: recipient.id,
      kind: "message",
      ciphertext: "ct",
      nonce: "n",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp thread_key(public_id) do
    Repo.get_by!(Envelope, public_id: public_id).thread_key
  end

  defp participants(public_id) do
    Repo.get_by!(Envelope, public_id: public_id).participants |> Jason.decode!()
  end
end
