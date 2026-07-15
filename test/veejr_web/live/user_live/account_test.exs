defmodule VeejrWeb.UserLive.AccountTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

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

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account")
    assert path == ~p"/users/log-in"
  end
end
