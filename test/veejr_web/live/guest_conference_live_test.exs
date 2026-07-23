defmodule VeejrWeb.GuestConferenceLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Calls, GuestConferences}

  @guest_key Base.encode64(:binary.copy(<<9>>, 32))

  setup %{conn: conn} do
    host = user_fixture(%{display_name: "Host Person"})

    {:ok, host} =
      Accounts.setup_user_keys(host, %{
        "public_key" => Base.encode64(:binary.copy(<<1>>, 32)),
        "enc_secret_key" => Base.encode64(:binary.copy(<<2>>, 48)),
        "key_salt" => Base.encode64(:binary.copy(<<3>>, 16)),
        "key_nonce" => Base.encode64(:binary.copy(<<4>>, 24))
      })

    assert_email_sent()

    %{conn: log_in_user(conn, host), public_conn: build_conn(), host: host}
  end

  test "host emails a no-account guest invitation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guest-conferences/new")

    assert has_element?(view, "#guest-conference-invite-form")

    view
    |> form("#guest-conference-invite-form",
      guest_conference: %{invited_email: "guest@example.com"}
    )
    |> render_submit()

    assert_redirect_matches(view, ~r|/guest-conferences/[^/]+$|)

    assert_email_sent(
      to: "guest@example.com",
      subject: "Host Person invited you to a private video call"
    )
  end

  test "guest enters the waiting room and only connects after host admission", %{
    conn: host_conn,
    public_conn: guest_conn,
    host: host
  } do
    {:ok, conference, token} =
      GuestConferences.create_invitation(host, %{invited_email: "guest@example.com"})

    {:ok, host_view, _html} =
      live(host_conn, ~p"/guest-conferences/#{conference.public_id}")

    {:ok, guest_view, _html} = live(guest_conn, ~p"/guest/#{token}")

    assert has_element?(guest_view, "#guest-device-lobby")
    refute has_element?(host_view, "#admit-guest")

    render_hook(guest_view, "guest_ready", %{
      "display_name" => "Expected Guest",
      "public_key" => @guest_key
    })

    assert has_element?(guest_view, "#guest-waiting")
    assert has_element?(host_view, "#admit-guest")
    assert has_element?(host_view, "#guest-conference-host", "Expected Guest")

    host_view |> element("#admit-guest") |> render_click()

    assert_redirect(
      host_view,
      ~p"/guest-conferences/#{conference.public_id}/call"
    )

    assert_redirect(guest_view, ~p"/guest/#{token}/call")

    {:ok, guest_call, _html} = live(guest_conn, ~p"/guest/#{token}/call")
    assert has_element?(guest_call, "#call-session[data-is-guest='true']")
    assert has_element?(guest_call, "#call-device-setup")

    guest_call |> element("#hang-up") |> render_click()
    assert_redirect(guest_call, ~p"/guest/#{token}")

    {:ok, complete, _html} = live(guest_conn, ~p"/guest/#{token}")
    assert has_element?(complete, "#guest-conference-complete")
    assert has_element?(complete, "#join-veejr-after-call")
  end

  test "post-call membership is optional and prefills the invited email", %{
    public_conn: guest_conn,
    host: host
  } do
    {:ok, conference, token} =
      GuestConferences.create_invitation(host, %{invited_email: "future@example.com"})

    {:ok, waiting} =
      GuestConferences.put_waiting(conference, %{
        display_name: "Future Member",
        public_key: @guest_key
      })

    {:ok, _call} = Calls.start_guest_call(host, waiting)
    :ok = Calls.end_guest_call(waiting)

    {:ok, view, _html} = live(guest_conn, ~p"/guest/#{token}")
    view |> element("#join-veejr-after-call") |> render_click()

    {path, _flash} = assert_redirect(view)
    assert path =~ "/users/register?"

    {:ok, registration, _html} = live(guest_conn, path)

    assert has_element?(
             registration,
             "#registration_form input[name='user[email]'][value='future@example.com']"
           )
  end

  defp assert_redirect_matches(view, regex) do
    {path, _flash} = assert_redirect(view)
    assert path =~ regex
  end
end
