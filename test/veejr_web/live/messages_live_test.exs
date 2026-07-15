defmodule VeejrWeb.MessagesLiveTest do
  use VeejrWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}

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

  test "starts with the newest 50 messages and loads older rows on demand", %{
    conn: conn,
    user: user
  } do
    copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => user.id,
              "ciphertext" => "ciphertext-#{index}",
              "nonce" => "nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    oldest = hd(copies)
    newest = List.last(copies)
    key = Messaging.conversation_key(["notes to yourself"])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}")
    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")

    view
    |> element("#load-more-messages")
    |> render_click()

    assert has_element?(view, "#message-shell-#{oldest.public_id}")
  end

  test "starts with the newest 50 for the selected conversation", %{conn: conn, user: user} do
    other = user_fixture()
    {:ok, friendship} = Social.send_friend_request(other, user.username)
    {:ok, _friendship} = Social.accept_friend_request(user, friendship.id)

    self_copies =
      for index <- 1..55 do
        {:ok, batch_id, []} =
          Messaging.send_batch(user, "message", [
            %{
              "recipient_id" => user.id,
              "ciphertext" => "self-ciphertext-#{index}",
              "nonce" => "self-nonce-#{index}"
            }
          ])

        Repo.get_by!(Veejr.Messaging.Envelope,
          batch_id: batch_id,
          recipient_id: user.id
        )
      end

    for index <- 1..60 do
      {:ok, _batch_id, []} =
        Messaging.send_batch(other, "message", [
          %{
            "recipient_id" => user.id,
            "ciphertext" => "other-ciphertext-#{index}",
            "nonce" => "other-nonce-#{index}"
          }
        ])
    end

    Repo.update_all(
      from(n in Veejr.Messaging.Notification, where: n.user_id == ^user.id),
      set: [state: "accepted"]
    )

    oldest = hd(self_copies)
    newest_visible = Enum.at(self_copies, 5)
    oldest_hidden = Enum.at(self_copies, 4)
    newest = List.last(self_copies)
    key = Messaging.conversation_key(["notes to yourself"])

    {:ok, view, _html} = live(conn, "/messages?conversation=#{key}")

    assert has_element?(view, "#message-shell-#{newest.public_id}")
    assert has_element?(view, "#message-shell-#{newest_visible.public_id}")
    refute has_element?(view, "#message-shell-#{oldest_hidden.public_id}")
    refute has_element?(view, "#message-shell-#{oldest.public_id}")
    assert has_element?(view, "#load-more-messages")
  end
end
