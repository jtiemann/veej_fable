defmodule VeejrWeb.UserLive.AccountTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Push}

  test "renders account links from the username destination", %{conn: conn} do
    user = user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert html =~ user.username
    assert html =~ ~p"/users/settings"
    assert html =~ ~p"/keys"
    assert html =~ ~p"/account/archives"
  end

  test "renders profile, identity, and FCM registration status", %{conn: conn} do
    user = user_fixture(%{display_name: "My nickname"})

    {:ok, session, _tokens} =
      Accounts.create_api_device_session(user, %{
        "device_name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "test"
      })

    assert :ok = Push.register_android_token(user, session.id, "fcm-token")

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert has_element?(view, "#account-nickname", "My nickname")
    assert has_element?(view, "#account-username", "@#{user.username}")
    assert has_element?(view, "#account-status[phx-hook=AccountStatus]")
    assert has_element?(view, "#account-fcm-status", "Registered")
  end

  test "reports FCM as not registered when no Android token exists", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account")

    assert has_element?(view, "#account-fcm-status", "Not registered")
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account")
    assert path == ~p"/users/log-in"
  end
end
