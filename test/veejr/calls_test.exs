defmodule Veejr.CallsTest do
  use Veejr.DataCase, async: false

  alias Veejr.{Calls, Social}
  alias Veejr.Calls.Call
  import Veejr.AccountsFixtures

  defp befriend(a, b) do
    {:ok, request} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, request.id)
  end

  defp subscribe_user(user) do
    Phoenix.PubSub.subscribe(Veejr.PubSub, "user:#{user.id}")
  end

  describe "local calls" do
    test "ringing an accepted friend broadcasts to their tabs" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)
      subscribe_user(bob)

      assert {:ok, call} = Calls.start_call(alice, bob.id)
      assert call.state == "ringing"
      assert_receive {:veejr_call_ring, %Call{public_id: public_id}}
      assert public_id == call.public_id
    end

    test "only accepted friends can ring" do
      alice = user_fixture()
      stranger = user_fixture()

      assert {:error, :not_a_friend} = Calls.start_call(alice, stranger.id)
      assert {:error, :self} = Calls.start_call(alice, alice.id)
    end

    test "only participants can see a call" do
      alice = user_fixture()
      bob = user_fixture()
      eve = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)

      assert {:ok, _} = Calls.get_call(alice, call.public_id)
      assert {:ok, _} = Calls.get_call(bob, call.public_id)
      assert {:error, :not_found} = Calls.get_call(eve, call.public_id)
    end

    test "joining answers the ring and unlocks signaling" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, call} = Calls.start_call(alice, bob.id)
      Calls.subscribe(call)

      # signaling is refused while still ringing
      assert {:error, {:bad_state, "ringing"}} = Calls.signal(alice, call.public_id, "ct", "n")

      assert {:ok, joined} = Calls.join_call(bob, call.public_id)
      assert joined.state == "accepted"
      assert_receive {:call_peer_joined, _id}

      assert :ok = Calls.signal(alice, call.public_id, "sealed-offer", "nonce")
      assert_receive {:call_signal, _id, from_id, "sealed-offer", "nonce"}
      assert from_id == alice.id

      # the caller cannot join as callee
      assert {:error, _} = Calls.join_call(alice, call.public_id)
    end

    test "decline and hang-up settle the call state" do
      alice = user_fixture()
      bob = user_fixture()
      befriend(alice, bob)

      {:ok, ringing} = Calls.start_call(alice, bob.id)
      Calls.subscribe(ringing)
      assert {:ok, declined} = Calls.decline_call(bob, ringing.public_id)
      assert declined.state == "declined"
      assert_receive {:call_ended, _id, "declined"}

      {:ok, second} = Calls.start_call(alice, bob.id)
      {:ok, _} = Calls.join_call(bob, second.public_id)
      Calls.subscribe(second)
      assert :ok = Calls.end_call(alice, second.public_id)
      assert_receive {:call_ended, _id, "ended"}
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, second.public_id)

      # cancelling an unanswered ring records a missed call
      {:ok, third} = Calls.start_call(alice, bob.id)
      assert :ok = Calls.end_call(alice, third.public_id)
      assert {:ok, %Call{state: "missed"}} = Calls.get_call(bob, third.public_id)
    end
  end

  describe "federated calls" do
    @remote_host "remote.example"

    setup do
      alice = user_fixture(%{username: "alice"})

      Req.Test.stub(Veejr.FederationStub, fn conn ->
        case conn.request_path do
          "/api/directory/carol" ->
            Req.Test.json(conn, %{
              username: "carol",
              public_key: Base.encode64("carol-key"),
              host: @remote_host
            })

          _ ->
            Req.Test.json(conn, %{ok: true})
        end
      end)

      {:ok, _} =
        Veejr.Federation.handle_friend_request(
          %{"from" => %{"username" => "carol", "authority" => @remote_host}, "to" => "alice"},
          @remote_host
        )

      [request] = Social.list_incoming_requests(alice)
      {:ok, fr} = Social.accept_friend_request(alice, request.id)
      {1, 0} = Veejr.Federation.Outbox.process_due()
      %{alice: alice, carol: fr.requester}
    end

    test "an inbound invite from a verified peer rings the local callee", %{
      alice: alice,
      carol: carol
    } do
      subscribe_user(alice)

      assert {:ok, :created} =
               Veejr.Federation.handle_call_invite(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "call_id" => "remote-call-1"
                 },
                 @remote_host
               )

      assert_receive {:veejr_call_ring, %Call{public_id: "remote-call-1"}}
      assert {:ok, %Call{caller_id: caller_id}} = Calls.get_call(alice, "remote-call-1")
      assert caller_id == carol.id

      # duplicate deliveries are absorbed
      assert {:ok, :duplicate} =
               Veejr.Federation.handle_call_invite(
                 %{
                   "from" => %{"username" => "carol", "authority" => @remote_host},
                   "to" => "alice",
                   "call_id" => "remote-call-1"
                 },
                 @remote_host
               )
    end

    test "remote updates and signals only land from the call's own peer", %{alice: alice} do
      {:ok, :created} =
        Veejr.Federation.handle_call_invite(
          %{
            "from" => %{"username" => "carol", "authority" => @remote_host},
            "to" => "alice",
            "call_id" => "remote-call-2"
          },
          @remote_host
        )

      # a different (even verified) authority cannot touch this call
      assert {:error, :origin_mismatch} =
               Calls.receive_remote_update("remote-call-2", "other.example", "ended")

      {:ok, call} = Calls.get_call(alice, "remote-call-2")
      Calls.subscribe(call)

      {:ok, _} = Calls.join_call(alice, "remote-call-2")

      assert {:ok, :relayed} =
               Calls.receive_remote_signal("remote-call-2", @remote_host, "sealed", "nonce")

      assert_receive {:call_signal, "remote-call-2", _from, "sealed", "nonce"}

      assert {:ok, :applied} = Calls.receive_remote_update("remote-call-2", @remote_host, "ended")
      assert {:ok, %Call{state: "ended"}} = Calls.get_call(alice, "remote-call-2")
    end

    test "calling a remote friend delivers a signed invite", %{alice: alice, carol: carol} do
      assert {:ok, call} = Calls.start_call(alice, carol.id)
      assert call.state == "ringing"
    end

    test "an unreachable callee instance fails the call cleanly", %{alice: alice, carol: carol} do
      Req.Test.stub(Veejr.FederationStub, fn conn ->
        Plug.Conn.send_resp(conn, 503, "down")
      end)

      assert {:error, :callee_unreachable} = Calls.start_call(alice, carol.id)
    end
  end

  test "the janitor sweep marks stale rings missed" do
    alice = user_fixture()
    bob = user_fixture()
    befriend(alice, bob)

    {:ok, call} = Calls.start_call(alice, bob.id)

    Repo.get_by!(Call, public_id: call.public_id)
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -120, :second))
    |> Repo.update!()

    assert %{missed: 1} = Calls.sweep_stale_calls()
    assert {:ok, %Call{state: "missed"}} = Calls.get_call(alice, call.public_id)
  end
end
