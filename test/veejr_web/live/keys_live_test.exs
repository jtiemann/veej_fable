defmodule VeejrWeb.KeysLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  test "returns a user without keys to the full calling conversation URL", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: to}}} = live(conn, "/messages?conversation=friend-42")
    assert to == "/keys?return_to=%2Fmessages%3Fconversation%3Dfriend-42"
  end

  test "carries a valid caller path through key setup", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, _view, html} = live(conn, "/keys?return_to=%2Fmessages%3Fconversation%3Dfriend-42")

    assert html =~ ~s(data-return-to="/messages?conversation=friend-42")
  end

  test "does not render an external return destination", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, _view, html} = live(conn, "/keys?return_to=https%3A%2F%2Fexample.com")

    refute html =~ "data-return-to=\"https://example.com\""
  end
end
