defmodule VeejrWeb.ProvisionerControllerTest do
  use VeejrWeb.ConnCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.AccountMoves

  setup do
    old_token = Application.get_env(:veejr, :provisioner_token)
    old_dir = Application.get_env(:veejr, :migration_dir)
    token = String.duplicate("p", 48)
    dir = Path.join(System.tmp_dir!(), "veejr-api-moves-#{System.unique_integer([:positive])}")
    Application.put_env(:veejr, :provisioner_token, token)
    Application.put_env(:veejr, :migration_dir, dir)

    on_exit(fn ->
      Application.put_env(:veejr, :provisioner_token, old_token)
      Application.put_env(:veejr, :migration_dir, old_dir)
      File.rm_rf(dir)
    end)

    %{token: token}
  end

  test "provisioner endpoints require the configured bearer token", %{conn: conn, token: token} do
    conn = post(conn, "/api/provisioner/v1/jobs/claim")
    assert json_response(conn, 401)["error"] == "unauthorized"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/provisioner/v1/jobs/claim")

    assert response(conn, 204) == ""
  end

  test "claims a package and records a verified result", %{conn: conn, token: token} do
    admin = user_fixture()
    member = user_fixture(%{username: "api_move"})

    {:ok, move} =
      AccountMoves.create(admin, member.id, %{
        "target_host" => "api.example.com",
        "instance_name" => "API target"
      })

    conn = authorized(conn, token) |> post("/api/provisioner/v1/jobs/claim")
    assert %{"job" => %{"id" => public_id, "phase" => "test"}} = json_response(conn, 200)
    assert public_id == move.public_id

    conn =
      authorized(build_conn(), token) |> get("/api/provisioner/v1/moves/#{public_id}/package")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-disposition") != []

    params = %{
      "phase" => "test",
      "success" => true,
      "receipt" => %{
        "package_sha256" => move.export_sha256,
        "owner" => move.username,
        "owner_admin" => true,
        "envelopes" => move.expected_envelopes,
        "blobs" => move.expected_blobs,
        "friends" => move.expected_friends
      }
    }

    conn =
      authorized(build_conn(), token)
      |> post("/api/provisioner/v1/moves/#{public_id}/result", params)

    assert json_response(conn, 200)["status"] == "test_verified"
  end

  defp authorized(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
