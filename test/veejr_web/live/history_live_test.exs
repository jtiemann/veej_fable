defmodule VeejrWeb.HistoryLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    %{conn: log_in_user(conn, user), user: user}
  end

  test "opens an item's originating conversation", %{conn: conn, user: user} do
    {:ok, batch_id, []} =
      Messaging.send_batch(user, "message", [
        %{"recipient_id" => user.id, "ciphertext" => "ciphertext", "nonce" => "nonce"}
      ])

    envelope =
      Repo.get_by!(Veejr.Messaging.Envelope,
        batch_id: batch_id,
        recipient_id: user.id
      )

    {:ok, view, _html} = live(conn, "/history")

    assert has_element?(
             view,
             "#history-open-#{envelope.public_id}[href='/messages?conversation=#{envelope.thread_key}']",
             "Open conversation"
           )
  end
end
