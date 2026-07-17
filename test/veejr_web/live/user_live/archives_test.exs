defmodule VeejrWeb.UserLive.ArchivesTest do
  use VeejrWeb.ConnCase

  alias Veejr.Messaging
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  test "lists and unarchives a conversation", %{conn: conn} do
    user = user_fixture()

    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "ct", "nonce" => "nonce"}
      ])

    Veejr.Repo.get_by!(Veejr.Messaging.Envelope, batch_id: batch_id, recipient_id: user.id)
    |> Ecto.Changeset.change(inserted_at: ~U[2026-07-01 09:30:00Z])
    |> Veejr.Repo.update!()

    key = Messaging.conversation_key(["notes to yourself"])
    assert {:ok, archive} = Messaging.archive_conversation(user, key)

    archive_key = archive.conversation_key

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/archives")

    assert html =~ "notes to yourself"
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
