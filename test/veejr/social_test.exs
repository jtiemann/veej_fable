defmodule Veejr.SocialTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.Social

  defp befriend(a, b) do
    {:ok, fr} = Social.send_friend_request(a, b.username)
    {:ok, _} = Social.accept_friend_request(b, fr.id)
    :ok
  end

  test "remove_friend deletes friendship and both users' group memberships" do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    befriend(alice, bob)

    {:ok, alice_group} = Social.create_group(alice, %{name: "Close"})
    {:ok, bob_group} = Social.create_group(bob, %{name: "Neighbors"})
    {:ok, _} = Social.add_group_member(alice, alice_group.id, bob.id)
    {:ok, _} = Social.add_group_member(bob, bob_group.id, alice.id)

    assert [_bob] = Social.group_members(alice, alice_group.id)
    assert [_alice] = Social.group_members(bob, bob_group.id)

    assert {:ok, _friendship} = Social.remove_friend(alice, bob.id)

    refute Social.friends?(alice.id, bob.id)
    assert [] = Social.group_members(alice, alice_group.id)
    assert [] = Social.group_members(bob, bob_group.id)
  end
end
