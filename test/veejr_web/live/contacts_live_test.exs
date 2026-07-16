defmodule VeejrWeb.ContactsLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Social}

  setup %{conn: conn} do
    user = user_fixture()
    friend = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)
    {:ok, group} = Social.create_group(user, %{name: "Close friends"})
    {:ok, _membership} = Social.add_group_member(user, group.id, friend.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend, group: group}
  end

  test "starts a new multi-selected conversation", %{conn: conn, friend: friend, group: group} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "#conversation-builder")
    assert has_element?(view, "input[name='selection[friend_ids][]'][value='#{friend.id}']")
    assert has_element?(view, "input[name='selection[group_ids][]'][value='#{group.id}']")

    view
    |> form("#conversation-builder-form", %{
      "selection" => %{
        "friend_ids" => [to_string(friend.id)],
        "group_ids" => [to_string(group.id)]
      }
    })
    |> render_submit()

    assert_redirect(
      view,
      "/messages?friend_ids=#{friend.id}&group_ids=#{group.id}&include_self=false"
    )
  end

  test "links to a scannable invitation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(view, "a[href='/invites/new']", "Invite person")

    {:ok, invite_view, html} = live(conn, "/invites/new")
    assert html =~ "Invite someone"
    assert has_element?(invite_view, "img[alt='QR code for this invitation']")
    assert has_element?(invite_view, "#invite-url[value^='http']")
  end

  test "shows a friend's uploaded image", %{conn: conn, friend: friend} do
    {:ok, _friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(
             view,
             "#friend-avatar-#{friend.id} img[src='/avatars/#{friend.username}?v=1']"
           )
  end

  test "shows and dismisses a joined invitation notice", %{conn: conn, user: user} do
    {:ok, invitation, token} = Accounts.create_invitation(user)
    {:ok, invited} = Accounts.register_user(valid_user_attributes(username: "new_joiner"), token)

    {:ok, view, html} = live(conn, "/contacts")
    assert html =~ "@new_joiner"
    assert has_element?(view, "#invitation-acceptances")

    view
    |> element(
      "button[phx-click='dismiss_invitation_acceptance'][phx-value-id='#{invitation.id}']"
    )
    |> render_click()

    refute has_element?(view, "#invitation-acceptances")
    assert Enum.any?(Social.list_friends(user), &(&1.id == invited.id))
  end

  test "opens an existing selected conversation", %{conn: conn, user: user, friend: friend} do
    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/contacts")

    assert has_element?(
             view,
             "input[name='selection[conversation_keys][]'][value='#{key}']"
           )

    view
    |> form("#conversation-builder-form", %{
      "selection" => %{"conversation_keys" => [key]}
    })
    |> render_submit()

    assert_redirect(view, "/messages?conversation=#{key}")
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
