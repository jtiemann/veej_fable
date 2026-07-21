defmodule VeejrWeb.CallLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, Messaging, Social}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    %{conn: log_in_user(conn, user), user: user, friend: friend}
  end

  test "ending a call returns to the exact originating conversation", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    return_to = "/messages?conversation=restored-thread-key"
    call_path = "/call/#{call.public_id}?" <> URI.encode_query(%{"return_to" => return_to})

    {:ok, view, _html} = live(conn, call_path)

    view |> element("#hang-up") |> render_click()

    assert_redirect(view, return_to)
  end

  test "renders local call quality feedback", %{conn: conn, user: user, friend: friend} do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-quality[data-role='call-quality']")
    assert has_element?(view, "#call-network-adjustment[data-role='call-notice']")
  end

  test "renders remote video viewing controls", %{conn: conn, user: user, friend: friend} do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-stage[data-role='call-stage']")
    assert has_element?(view, "#call-remote-video[data-role='remote-video']")
    assert has_element?(view, "#call-share-status[data-role='remote-share-status']")
    assert has_element?(view, "#call-fit[data-role='toggle-fit']")
    assert has_element?(view, "#call-pip[data-role='toggle-pip']")
    assert has_element?(view, "#call-popout[data-role='popout-share']")
    assert has_element?(view, "#call-fullscreen[data-role='toggle-fullscreen']")
  end

  test "renders the peer-to-peer call chat and file drop target", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-chat-toggle[data-role='toggle-chat']")
    assert has_element?(view, "#call-chat-panel[data-role='chat-panel']")
    assert has_element?(view, "#call-chat-messages[aria-live='polite']")
    assert has_element?(view, "#call-chat-dropzone[data-role='chat-dropzone']")
    assert has_element?(view, "#call-chat-input[maxlength='4000']")
    assert has_element?(view, "#call-chat-files[type='file'][multiple]")
    assert has_element?(view, "#call-chat-send[disabled]")
  end

  test "renders the private device setup before joining", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    assert has_element?(view, "#call-device-setup[data-role='device-setup']")
    assert has_element?(view, "#call-microphone[data-role='microphone-select']")
    assert has_element?(view, "#call-camera[data-role='camera-select']")
    assert has_element?(view, "#call-join[disabled]")
    assert has_element?(view, "#call-devices[data-role='open-devices']")
  end

  test "an incoming call without an origin returns to the peer conversation", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(friend, user.id)
    key = Messaging.conversation_key([Social.Address.handle(friend)])

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}")

    send(view.pid, {:call_ended, call.public_id, "ended"})

    assert_redirect(view, "/messages?conversation=#{key}")
  end

  test "does not accept an external return destination", %{
    conn: conn,
    user: user,
    friend: friend
  } do
    {:ok, call} = Calls.start_call(user, friend.id)
    key = Messaging.conversation_key([Social.Address.handle(friend)])
    query = URI.encode_query(%{"return_to" => "https://example.com/phishing"})

    {:ok, view, _html} = live(conn, "/call/#{call.public_id}?#{query}")

    view |> element("#hang-up") |> render_click()

    assert_redirect(view, "/messages?conversation=#{key}")
  end
end
