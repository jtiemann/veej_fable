defmodule VeejrWeb.BlobControllerTest do
  use VeejrWeb.ConnCase, async: true

  import Veejr.AccountsFixtures

  alias Veejr.Messaging

  describe "GET /api/blobs/:id (public capability)" do
    setup do
      owner = user_fixture()
      {:ok, blob} = Messaging.create_blob(owner, "encrypted-bytes-here")
      %{blob: blob}
    end

    test "serves the encrypted bytes with permissive CORS, no session", %{conn: conn, blob: blob} do
      conn = get(conn, ~p"/api/blobs/#{blob.public_id}")

      assert conn.status == 200
      assert response(conn, 200) == "encrypted-bytes-here"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert ["application/octet-stream" <> _] = get_resp_header(conn, "content-type")
    end

    test "404s on an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/blobs/does-not-exist")
      assert conn.status == 404
    end
  end
end
