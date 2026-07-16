defmodule VeejrWeb.AdminLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.Accounts

  test "renders the administrator dashboard", %{conn: conn} do
    admin = user_fixture()
    {:ok, invitation, _token} = Accounts.create_invitation(admin)

    {:ok, view, html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert html =~ "Instance administration"
    assert has_element?(view, "#admin-health", "All monitored services operational")
    assert has_element?(view, "#metric-local-users", "1")
    assert has_element?(view, "#metric-storage")
    assert has_element?(view, "button[phx-click='refresh']")
    assert has_element?(view, "#admin-invitations a[href='/invites/new']")
    assert has_element?(view, "#invitation-#{invitation.id}", "Active")
    assert has_element?(view, "#invitation-#{invitation.id} button", "Revoke")

    view |> element("button[phx-click='refresh']") |> render_click()
    assert has_element?(view, "#admin-health")
  end

  test "revokes an active invitation", %{conn: conn} do
    admin = user_fixture()
    {:ok, invitation, token} = Accounts.create_invitation(admin)

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    view
    |> element("#invitation-#{invitation.id} button", "Revoke")
    |> render_click()

    assert has_element?(view, "#invitation-#{invitation.id}", "Revoked")
    refute has_element?(view, "#invitation-#{invitation.id} button", "Revoke")
    refute Accounts.get_open_invitation(token)
  end

  test "lists local accounts and revokes member sessions", %{conn: conn} do
    admin = user_fixture()
    member = user_fixture(%{display_name: "Session Member"})
    web_token = Accounts.generate_user_session_token(member)

    {:ok, _device_session, api_tokens} =
      Accounts.create_api_device_session(member, %{
        "device_name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "test"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert has_element?(view, "#account-#{admin.id}", "Instance admin")
    assert has_element?(view, "#account-#{member.id}", "Session Member")
    assert has_element?(view, "#account-#{member.id}", "Test Pixel") == false

    assert has_element?(
             view,
             "#account-#{member.id} button[phx-click='revoke_user_sessions']",
             "Revoke sessions"
           )

    view
    |> element("#account-#{member.id} button[phx-click='revoke_user_sessions']")
    |> render_click()

    refute has_element?(view, "#account-#{member.id} button", "Revoke sessions")
    assert has_element?(view, "#account-#{member.id}", "Never")
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_and_api_session_by_access_token(api_tokens.access_token)
  end

  test "suspends and reactivates a member", %{conn: conn} do
    admin = user_fixture()
    member = user_fixture()
    token = Accounts.generate_user_session_token(member)

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert has_element?(view, "#account-#{member.id} button", "Suspend")

    view
    |> element("#account-#{member.id} button[phx-click='suspend_user']")
    |> render_click()

    assert has_element?(view, "#account-#{member.id}", "Suspended")
    assert has_element?(view, "#account-#{member.id} button", "Reactivate")
    refute Accounts.get_user_by_session_token(token)

    view
    |> element("#account-#{member.id} button[phx-click='reactivate_user']")
    |> render_click()

    assert has_element?(view, "#account-#{member.id}", "Confirmed")
    assert has_element?(view, "#account-#{member.id} button", "Suspend")
  end

  test "redirects ordinary members", %{conn: conn} do
    _admin = user_fixture()
    member = user_fixture()

    assert {:error, {:redirect, %{to: path, flash: flash}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/admin")

    assert path == ~p"/contacts"
    assert flash["error"] =~ "Only the instance administrator"
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
    assert path == ~p"/users/log-in"
  end
end
