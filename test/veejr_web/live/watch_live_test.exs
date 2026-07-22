defmodule VeejrWeb.WatchLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, WatchParties}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    if party = WatchParties.active_party() do
      WatchParties.end_party(party.public_id, party.host_id)
    end

    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders the watch lobby and validates YouTube input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/watch")

    assert has_element?(view, "#watch-lobby")
    assert has_element?(view, "#watch-start-form")

    view
    |> form("#watch-start-form", watch: %{url: "https://example.com/not-youtube"})
    |> render_submit()

    assert has_element?(view, "#watch-start-form")
  end

  test "the initiator starts a host-controlled player", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/watch")

    view
    |> form("#watch-start-form", watch: %{url: "https://youtu.be/dQw4w9WgXcQ"})
    |> render_submit()

    party = WatchParties.active_party()
    assert_redirect(view, "/watch/#{party.public_id}")

    {:ok, host_view, _html} = live(conn, "/watch/#{party.public_id}")
    assert has_element?(host_view, "#youtube-watch-player[data-host='true']")
    assert has_element?(host_view, "#youtube-watch-iframe[src*='youtube-nocookie.com']")
    assert has_element?(host_view, "#watch-end")

    host_view |> element("#watch-end") |> render_click()
    assert_redirect(host_view, "/watch")
    assert is_nil(WatchParties.active_party())
    assert user.id == party.host_id
  end
end
