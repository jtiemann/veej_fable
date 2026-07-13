defmodule VeejrWeb.Api.V1.MessageDeliveryPolicyControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Social}

  setup %{conn: conn} do
    alice = keyed_user("api_policy_alice") |> set_password()
    bob = keyed_user("api_policy_bob")
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _friendship} = Social.accept_friend_request(bob, request.id)
    tokens = login(conn, alice)
    %{alice: alice, bob: bob, tokens: tokens}
  end

  test "creates, lists, and removes a contact override", %{conn: conn, bob: bob, tokens: tokens} do
    response =
      conn
      |> authorize(tokens)
      |> put("/api/v1/contacts/#{bob.id}/message-delivery-policy", %{
        "acceptance" => "automatic",
        "notification" => "normal"
      })
      |> json_response(200)

    assert response["policy"]["subject_type"] == "contact"
    assert response["policy"]["acceptance"] == "automatic"

    policies =
      build_conn()
      |> authorize(tokens)
      |> get("/api/v1/message-delivery-policies")
      |> json_response(200)

    assert [response["policy"]] == policies["policies"]

    contacts =
      build_conn()
      |> authorize(tokens)
      |> get("/api/v1/contacts")
      |> json_response(200)

    assert [%{"auto_accept" => true}] = contacts["contacts"]

    delete_conn =
      build_conn()
      |> authorize(tokens)
      |> delete("/api/v1/contacts/#{bob.id}/message-delivery-policy")

    assert response(delete_conn, 204) == ""
  end

  test "rejects subjects outside the authenticated owner's address book", %{
    conn: conn,
    tokens: tokens
  } do
    stranger = keyed_user("api_policy_eve")

    response =
      conn
      |> authorize(tokens)
      |> put("/api/v1/contacts/#{stranger.id}/message-delivery-policy", %{
        "acceptance" => "automatic",
        "notification" => "normal"
      })
      |> json_response(404)

    assert response["error"]["code"] == "not_found"
  end

  test "validates policy values", %{conn: conn, bob: bob, tokens: tokens} do
    response =
      conn
      |> authorize(tokens)
      |> put("/api/v1/conversations/#{bob.id}/message-delivery-policy", %{
        "acceptance" => "always",
        "notification" => "loud"
      })
      |> json_response(422)

    assert response["error"]["code"] == "invalid_policy"
  end

  test "lists only the caller's groups for native policy controls", %{
    conn: conn,
    alice: alice,
    bob: bob,
    tokens: tokens
  } do
    {:ok, group} = Social.create_group(alice, %{name: "Inner circle"})
    {:ok, _membership} = Social.add_group_member(alice, group.id, bob.id)
    {:ok, _other_group} = Social.create_group(bob, %{name: "Not Alice's"})

    response =
      conn
      |> authorize(tokens)
      |> get("/api/v1/groups")
      |> json_response(200)

    assert [%{"id" => id, "name" => "Inner circle", "members" => [member]}] =
             response["groups"]

    assert id == to_string(group.id)
    assert member == %{"id" => to_string(bob.id), "handle" => "@api_policy_bob"}
  end

  test "updates private contact and group notes through owner-scoped native routes", %{
    conn: conn,
    alice: alice,
    bob: bob,
    tokens: tokens
  } do
    {:ok, group} = Social.create_group(alice, %{name: "Notes group"})

    contact_note =
      conn
      |> authorize(tokens)
      |> put("/api/v1/contacts/#{bob.id}/note", %{"body" => "Met in Berlin"})
      |> json_response(200)

    group_note =
      build_conn()
      |> authorize(tokens)
      |> put("/api/v1/groups/#{group.id}/note", %{"body" => "Weekend planning"})
      |> json_response(200)

    assert contact_note["note"] == %{
             "subject_id" => to_string(bob.id),
             "body" => "Met in Berlin"
           }

    assert group_note["note"] == %{
             "subject_id" => to_string(group.id),
             "body" => "Weekend planning"
           }

    contacts =
      build_conn()
      |> authorize(tokens)
      |> get("/api/v1/contacts")
      |> json_response(200)

    groups =
      build_conn()
      |> authorize(tokens)
      |> get("/api/v1/groups")
      |> json_response(200)

    assert [%{"note" => "Met in Berlin"}] = contacts["contacts"]
    assert [%{"note" => "Weekend planning"}] = groups["groups"]
  end

  defp keyed_user(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(:binary.copy(<<1>>, 32)),
        enc_secret_key: Base.encode64(:binary.copy(<<2>>, 48)),
        key_salt: Base.encode64(:binary.copy(<<3>>, 16)),
        key_nonce: Base.encode64(:binary.copy(<<4>>, 24))
      })

    user
  end

  defp login(conn, user) do
    conn
    |> post("/api/v1/auth/login", %{
      "email" => user.email,
      "password" => valid_user_password(),
      "device" => %{
        "name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "0.1.0-alpha01"
      }
    })
    |> json_response(200)
    |> get_in(["tokens", "access_token"])
  end

  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
