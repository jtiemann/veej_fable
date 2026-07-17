defmodule Veejr.KeyRotationTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.Accounts.User
  alias Veejr.{Accounts, Federation, Messaging, Repo, Social}

  @remote_host "remote.example"

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

  defp send_message(from, to, ciphertext) do
    {:ok, batch_id, _} =
      Messaging.send_batch(from, "message", [
        %{"recipient_id" => to.id, "ciphertext" => ciphertext, "nonce" => "n"},
        %{"recipient_id" => from.id, "ciphertext" => ciphertext <> "-self", "nonce" => "n"}
      ])

    batch_id
  end

  defp accept_all(user) do
    for n <- Messaging.list_pending_notifications(user) do
      {:ok, _} = Messaging.accept_notification(user, n.id)
    end
  end

  test "passphrase change replaces only the wrapper, never the keypair" do
    user = user_with_keys("alice")
    original_public = user.public_key

    {:ok, updated} =
      Accounts.rewrap_user_keys(user, %{
        "enc_secret_key" => Base.encode64("rewrapped"),
        "key_salt" => Base.encode64("salt2"),
        "key_nonce" => Base.encode64("nonce2")
      })

    assert updated.public_key == original_public
    assert updated.enc_secret_key == Base.encode64("rewrapped")
  end

  test "envelopes snapshot the sender key; rotation cannot break friends' history" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)

    send_message(alice, bob, "ct-old")
    accept_all(bob)

    alice_old_key = alice.public_key

    {:ok, rotated_alice} =
      Accounts.rotate_user_keys(alice, %{
        "public_key" => Base.encode64("pub-alice-NEW"),
        "enc_secret_key" => Base.encode64("wrapped-NEW"),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    # bob's received copy still decrypts against alice's OLD key
    [envelope] = Messaging.list_history(bob)
    assert Messaging.peer_key(envelope, bob) == alice_old_key
    refute Messaging.peer_key(envelope, bob) == rotated_alice.public_key
  end

  test "resealing swaps ciphertext and decrypts against the owner's current key" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)
    send_message(alice, bob, "ct-v1")
    accept_all(bob)

    [envelope] = Messaging.list_history(bob)

    {:ok, 1} =
      Messaging.reseal_envelopes(bob, [
        %{"public_id" => envelope.public_id, "ciphertext" => "ct-resealed", "nonce" => "n2"}
      ])

    [resealed] = Messaging.list_history(bob)
    assert resealed.ciphertext == "ct-resealed"
    assert resealed.resealed
    # now opens against bob's own (current) key
    assert Messaging.peer_key(resealed, bob) == bob.public_key

    # resealing never touches other people's copies
    refute Repo.get_by(Veejr.Messaging.Envelope, recipient_id: alice.id).resealed
  end

  test "reset purges only the user's received copies" do
    alice = user_with_keys("alice")
    bob = user_with_keys("bob")
    befriend(alice, bob)
    send_message(alice, bob, "ct")
    accept_all(bob)

    {:ok, purged} = Messaging.purge_received_envelopes(bob)
    assert purged == 1
    assert Messaging.list_history(bob) == []
    # alice's self-copy survives
    assert [_] = Messaging.list_history(alice)
  end

  describe "key updates over federation" do
    setup do
      alice = user_with_keys("alice")

      Req.Test.stub(Veejr.FederationStub, fn conn ->
        case conn.request_path do
          "/api/directory/carol" ->
            Req.Test.json(conn, %{
              username: "carol",
              public_key: Base.encode64("carol-key-v1"),
              host: @remote_host
            })

          _ ->
            Req.Test.json(conn, %{ok: true})
        end
      end)

      {:ok, _} =
        Federation.handle_friend_request(
          %{"from" => %{"username" => "carol", "authority" => @remote_host}, "to" => "alice"},
          @remote_host
        )

      [request] = Social.list_incoming_requests(alice)
      {:ok, fr} = Social.accept_friend_request(alice, request.id)
      # deliver the queued friend_response so tests start with an empty outbox
      {1, 0} = Veejr.Federation.Outbox.process_due()
      %{alice: alice, carol: fr.requester}
    end

    test "an announced key change is held pending until a human confirms", %{
      alice: alice,
      carol: carol
    } do
      new_key = Base.encode64("carol-key-v2")

      {:ok, _} =
        Federation.handle_key_update(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "public_key" => new_key
          },
          @remote_host
        )

      carol_row = Repo.get(User, carol.id)
      # not swapped yet — messages would still encrypt to the old key
      assert carol_row.public_key == Base.encode64("carol-key-v1")
      assert carol_row.pending_public_key == new_key

      {:ok, confirmed} = Social.confirm_new_key(alice, carol.id)
      assert confirmed.public_key == new_key
      assert confirmed.pending_public_key == nil
    end

    test "announcements for unknown users are rejected" do
      assert {:error, :unknown_recipient} =
               Federation.handle_key_update(
                 %{
                   "from" => %{"username" => "nobody", "authority" => @remote_host},
                   "public_key" => Base.encode64("x")
                 },
                 @remote_host
               )
    end

    test "rotation announces the new key to remote friends' instances", %{alice: alice} do
      {:ok, alice} =
        Accounts.rotate_user_keys(alice, %{
          "public_key" => Base.encode64("pub-alice-NEW"),
          "enc_secret_key" => Base.encode64("w"),
          "key_salt" => Base.encode64("s"),
          "key_nonce" => Base.encode64("n")
        })

      assert :ok = Federation.announce_key_update(alice)
      # queued transactionally; the outbox delivers via the stub
      assert Veejr.Federation.Outbox.pending_count() == 1
      assert {1, 0} = Veejr.Federation.Outbox.process_due()
      assert Veejr.Federation.Outbox.pending_count() == 0
    end
  end
end
