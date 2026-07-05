defmodule Veejr.ImportReconnectTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Import, Social}

  defp user_with_keys(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  test "import reconnect sends friend requests to exported friends" do
    owner = user_with_keys("mover")

    Req.Test.stub(Veejr.FederationStub, fn conn ->
      case conn.request_path do
        "/api/directory/carol" ->
          Req.Test.json(conn, %{
            username: "carol",
            public_key: Base.encode64("carol-key"),
            host: "old-home.example"
          })

        "/api/directory/dave" ->
          Plug.Conn.send_resp(conn, 404, "{}")

        _ ->
          Req.Test.json(conn, %{ok: true})
      end
    end)

    results =
      Import.reconnect_friends(owner, [
        %{"username" => "carol", "host" => "old-home.example"},
        %{"username" => "dave", "host" => "old-home.example"}
      ])

    assert {"@carol@old-home.example", :request_sent} in results
    assert {"@dave@old-home.example", :unknown_user} in results
    assert [_] = Social.list_outgoing_requests(owner)
  end
end
