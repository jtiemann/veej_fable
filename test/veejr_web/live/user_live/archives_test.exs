defmodule VeejrWeb.UserLive.ArchivesTest do
  use VeejrWeb.ConnCase

  alias Veejr.Messaging
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  test "lists and unarchives a conversation", %{conn: conn} do
    user = user_fixture()
    participants = ["@alice@example.test"]
    key = Messaging.conversation_key(participants)
    started_at = ~U[2026-07-01 09:30:00Z]

    assert {:ok, archive} =
             Messaging.archive_conversation(user, key, participants, ["message-1"], started_at)

    archive_key = archive.conversation_key

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/archives")

    assert html =~ "@alice@example.test"
    assert html =~ "Started Jul 01, 2026"
    assert has_element?(view, "#archive-#{archive_key}")

    view
    |> element("#unarchive-#{archive_key}")
    |> render_click()

    refute has_element?(view, "#archive-#{archive_key}")
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account/archives")
    assert path == ~p"/users/log-in"
  end
end
