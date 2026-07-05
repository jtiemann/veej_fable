defmodule Veejr.ExportImportTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Export, Import, Messaging, Repo, Social}
  alias Veejr.Accounts.User

  defp user_with_keys(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  defp befriend(a, b) do
    {:ok, fr} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, fr.id)
    :ok
  end

  test "export → delete → import round-trips an account" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    # alice sends bob a message (with her self-copy)
    {:ok, _batch} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct-for-bob", "nonce" => "n1"},
        %{"recipient_id" => alice.id, "ciphertext" => "ct-for-alice", "nonce" => "n2"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)

    # bob uploads an (already encrypted) attachment blob
    {:ok, blob} = Messaging.create_blob(bob, "encrypted-bytes")

    # export bob
    {:ok, filename, zip} = Export.build(bob)
    assert filename == "veejr-bob-export.zip"

    {:ok, files} = :zip.unzip(zip, [:memory])
    files = Map.new(files, fn {name, bin} -> {to_string(name), bin} end)
    manifest = Jason.decode!(files["export.json"])

    assert manifest["veejr_export"] == 1
    assert manifest["profile"]["username"] == "bob"
    assert manifest["keys"]["public_key"] == bob.public_key
    assert [%{"username" => "alice"}] = manifest["friends"]
    assert [envelope_entry] = manifest["envelopes"]
    assert envelope_entry["ciphertext"] == "ct-for-bob"
    assert envelope_entry["sender"]["username"] == "alice"
    assert envelope_entry["sender"]["public_key"] == alice.public_key
    assert files["blobs/#{blob.public_id}.bin"] == "encrypted-bytes"

    # bob leaves the community server
    {:ok, _} = Accounts.delete_user(bob)
    refute Accounts.get_user_by_username("bob")
    assert Messaging.get_blob(blob.public_id) == nil
    refute File.exists?(blob.path)

    # ... and restores on a "personal instance"
    {:ok, summary} = Import.from_zip(zip)
    assert summary.owner == "bob"
    assert summary.envelopes == 1
    assert summary.blobs == 1

    new_bob = Accounts.get_user_by_username("bob")
    assert new_bob.public_key == bob.public_key
    assert new_bob.enc_secret_key == bob.enc_secret_key
    assert new_bob.confirmed_at

    # history is back, sender resolves (alice still exists here, so no ghost)
    [restored] = Messaging.list_history(new_bob)
    assert restored.ciphertext == "ct-for-bob"
    assert restored.public_id == envelope_entry["public_id"]
    assert restored.sender.username == "alice"

    # blob is back on disk
    restored_blob = Messaging.get_blob(blob.public_id)
    assert File.read!(restored_blob.path) == "encrypted-bytes"

    # re-import is rejected (owner exists)
    assert {:error, :owner_already_exists} = Import.from_zip(zip)
  end

  test "import creates ghost contacts for senders unknown to this instance" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    {:ok, _} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct", "nonce" => "n"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    {:ok, _, zip} = Export.build(bob)

    # simulate a truly fresh personal instance: neither bob nor alice exist
    {:ok, _} = Accounts.delete_user(bob)
    {:ok, _} = Accounts.delete_user(alice)

    {:ok, summary} = Import.from_zip(zip)
    assert summary.ghost_contacts == 1

    ghost = Accounts.get_user_by_username("alice")
    assert ghost.public_key == alice.public_key
    assert ghost.email =~ ".invalid"
    # ghosts have no wrapped secret key and can never log in or decrypt
    refute ghost.enc_secret_key

    new_bob = Accounts.get_user_by_username("bob")
    [restored] = Messaging.list_history(new_bob)
    assert restored.sender_id == ghost.id
  end

  test "export requires nothing beyond ciphertext — plaintext never appears" do
    bob = user_with_keys("bob")
    {:ok, _, zip} = Export.build(bob)
    {:ok, files} = :zip.unzip(zip, [:memory])
    manifest = Jason.decode!(Map.new(files, fn {n, b} -> {to_string(n), b} end)["export.json"])

    # the wrapped secret key is present, a raw secret key is not a concept
    # the server ever has — spot-check the manifest keys
    assert Map.keys(manifest["keys"]) |> Enum.sort() ==
             ["enc_secret_key", "key_nonce", "key_salt", "public_key"]
  end

  test "delete_user withdraws sent envelopes from recipients" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    {:ok, _} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "ct", "nonce" => "n"}
      ])

    [notification] = Messaging.list_pending_notifications(bob)
    {:ok, _} = Messaging.accept_notification(bob, notification.id)
    assert [_] = Messaging.list_history(bob)

    {:ok, _} = Accounts.delete_user(alice)

    # sender owns the data: deletion withdraws it everywhere
    assert Messaging.list_history(bob) == []
    assert Repo.aggregate(User, :count) == 1
  end
end
