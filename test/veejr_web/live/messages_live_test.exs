defmodule VeejrWeb.MessagesLiveTest do
  use VeejrWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    %{conn: log_in_user(conn, user), user: user}
  end

  test "uses a back-to-contacts link instead of new-chat buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#back-to-contacts[href='/contacts']", "Back to contacts")
    refute has_element?(view, "#compose-new")
    refute has_element?(view, "#new-message")
  end

  test "offers encrypted voice and video recording controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/messages")

    assert has_element?(view, "#message-composer [data-role='audio-toggle']")

    assert has_element?(
             view,
             "#message-composer [data-role='video-toggle'][aria-pressed='false']"
           )

    assert has_element?(view, "#message-composer [data-role='video-facing-toggle']")
    assert has_element?(view, "#message-composer [data-role='video-status'][aria-live='polite']")
    assert has_element?(view, "#message-composer [data-role='video-preview']")
  end

  test "opens a new conversation with multiple recipients preselected", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, view, html} =
      live(conn, "/messages?friend_ids=#{friend.id}&group_ids=&include_self=false")

    assert html =~ "New conversation"
    assert html =~ "1 selected recipient"

    assert has_element?(
             view,
             "#message-composer input[type='hidden'][name='friends[]'][value='#{friend.id}']"
           )
  end

  test "shows a friend's image when starting a conversation", %{conn: conn, user: user} do
    friend = user_fixture()
    {:ok, friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, view, _html} = live(conn, "/messages?friend_id=#{friend.id}")

    assert has_element?(
             view,
             "#message-friend-avatar-#{friend.id} img[src='/avatars/#{friend.username}?v=1']"
           )

    assert has_element?(view, "main img[src='/avatars/#{friend.username}?v=1']")
  end

  test "opens a contact profile and saves notes from messages", %{conn: conn, user: user} do
    friend = user_fixture(%{display_name: "Profile Friend"})
    {:ok, friend} = Accounts.put_user_avatar(friend, jpeg())
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)
    {:ok, view, _html} = live(conn, "/messages?friend_id=#{friend.id}")

    view |> element("#selected-recipient-avatar") |> render_click()

    assert has_element?(view, "#profile-dialog", "Profile Friend")
    assert has_element?(view, "#profile-dialog img[src='/avatars/#{friend.username}?v=1']")

    view
    |> form("#profile-dialog form", %{
      "contact_id" => to_string(friend.id),
      "body" => "Follow up next Tuesday"
    })
    |> render_submit()

    assert Social.list_contact_notes(user)[friend.id] == "Follow up next Tuesday"
    assert has_element?(view, "#profile-note", "Follow up next Tuesday")
  end

  test "conversation rail avatar opens the profile instead of selecting the thread", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture(%{display_name: "Rail Profile"})
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/messages")

    view |> element("#rail-conversation-avatar-#{key}") |> render_click()

    assert has_element?(view, "#profile-dialog", "Rail Profile")
    refute has_element?(view, "#thread-#{key}")

    view |> element("button[phx-click='close_profile']") |> render_click()
    view |> element("#conversation-#{key}") |> render_click()
    assert_patch(view, "/messages?conversation=#{key}")
    assert has_element?(view, "#thread-#{key}")
  end

  test "starts a call with the selected conversation as its return destination", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, _batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => friend.id, "ciphertext" => "friend", "nonce" => "nonce-1"},
        %{"recipient_id" => user.id, "ciphertext" => "self", "nonce" => "nonce-2"}
      ])

    key = Messaging.conversation_key([Social.Address.handle(friend)])
    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    view |> element("#start-call") |> render_click()
    {call_path, _flash} = assert_redirect(view)
    call_uri = URI.parse(call_path)

    assert String.starts_with?(call_uri.path, "/call/")
    assert URI.decode_query(call_uri.query)["return_to"] == "/messages?conversation=#{key}"
  end

  test "starts with the newest 50 messages and loads older rows on demand", %{
    conn: conn,
    user: user
  } do
    copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => user.id,
              "ciphertext" => "ciphertext-#{index}",
              "nonce" => "nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    oldest = hd(copies)
    newest = List.last(copies)
    key = Messaging.conversation_key(["notes to yourself"])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}")
    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")

    view
    |> element("#load-more-messages")
    |> render_click()

    assert has_element?(view, "#message-shell-#{oldest.public_id}")
  end

  test "starts with the newest 50 for the selected conversation", %{conn: conn, user: user} do
    other = user_fixture()
    {:ok, friendship} = Social.send_friend_request(other, user.username)
    {:ok, _friendship} = Social.accept_friend_request(user, friendship.id)

    self_copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => user.id,
              "ciphertext" => "self-ciphertext-#{index}",
              "nonce" => "self-nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    for index <- 1..60 do
      {:ok, _batch_id, []} =
        Messaging.send_batch(other, "message", [
          %{
            "recipient_id" => user.id,
            "ciphertext" => "other-ciphertext-#{index}",
            "nonce" => "other-nonce-#{index}"
          }
        ])
    end

    Repo.update_all(
      from(n in Veejr.Messaging.Notification, where: n.user_id == ^user.id),
      set: [state: "accepted"]
    )

    oldest = hd(self_copies)
    newest_visible = Enum.at(self_copies, 5)
    oldest_hidden = Enum.at(self_copies, 4)
    newest = List.last(self_copies)
    key = Messaging.conversation_key(["notes to yourself"])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}")
    assert has_element?(view, "#message-shell-#{newest_visible.public_id}")
    refute has_element?(view, "#message-shell-#{oldest_hidden.public_id}")
    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")
  end

  test "labels a restored conversation with its start date", %{conn: conn, user: user} do
    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "first", "nonce" => "nonce"}
      ])

    envelope =
      Repo.get_by!(Veejr.Messaging.Envelope,
        batch_id: batch_id,
        recipient_id: user.id
      )

    current_key = Messaging.conversation_key(["notes to yourself"])

    assert {:ok, archive} = Messaging.archive_conversation(user, current_key)
    assert :ok = Messaging.unarchive_conversation(user, archive.conversation_key)

    {:ok, _view, html} = live(conn, "/messages?conversation=#{archive.conversation_key}")

    assert html =~
             "notes to yourself · #{Calendar.strftime(envelope.inserted_at, "%b %d, %Y")}"
  end

  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 512::16, 512::16, 0::size(12)-unit(8), 0xFF,
      0xD9>>
  end
end
