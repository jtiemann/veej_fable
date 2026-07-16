defmodule VeejrWeb.AdminLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  test "renders the administrator dashboard", %{conn: conn} do
    admin = user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/admin")

    assert html =~ "Instance administration"
    assert has_element?(view, "#admin-health", "All monitored services operational")
    assert has_element?(view, "#metric-local-users", "1")
    assert has_element?(view, "#metric-storage")
    assert has_element?(view, "button[phx-click='refresh']")

    view |> element("button[phx-click='refresh']") |> render_click()
    assert has_element?(view, "#admin-health")
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
