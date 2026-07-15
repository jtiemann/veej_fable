defmodule VeejrWeb.UserLive.ArchivesTest do
  use VeejrWeb.ConnCase

  alias Veejr.Messaging
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  test "lists and unarchives a conversation", %{conn: conn} do
    user = user_fixture()
    participants = ["@alice@example.test"]
    key = Messaging.conversation_key(participants)
    assert {:ok, _} = Messaging.archive_conversation(user, key, participants)

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/archives")

    assert html =~ "@alice@example.test"
    assert has_element?(view, "#archive-#{key}")

    view
    |> element("#unarchive-#{key}")
    |> render_click()

    refute has_element?(view, "#archive-#{key}")
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account/archives")
    assert path == ~p"/users/log-in"
  end
end
