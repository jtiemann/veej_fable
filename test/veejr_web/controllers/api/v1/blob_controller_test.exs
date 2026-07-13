defmodule VeejrWeb.Api.V1.BlobControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  test "uploads opaque attachment ciphertext for the authenticated device", %{conn: conn} do
    user = user_fixture() |> set_password()
    tokens = login(conn, user)
    ciphertext = :crypto.strong_rand_bytes(128)

    idempotency_key = String.duplicate("b", 22)

    response =
      build_conn()
      |> authorize(tokens["access_token"])
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post("/api/v1/blobs", ciphertext)
      |> json_response(201)

    assert response["size"] == byte_size(ciphertext)
    assert is_binary(response["id"])

    replay =
      build_conn()
      |> authorize(tokens["access_token"])
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post("/api/v1/blobs", ciphertext)
      |> json_response(200)

    assert replay == response

    downloaded =
      build_conn()
      |> get("/api/blobs/#{response["id"]}")
      |> response(200)

    assert downloaded == ciphertext
  end

  test "requires an Android bearer session", %{conn: conn} do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> post("/api/v1/blobs", "ciphertext")
    |> json_response(401)
  end

  defp login(conn, user) do
    conn
    |> post("/api/v1/auth/login", %{
      "email" => user.email,
      "password" => valid_user_password(),
      "device" => %{
        "name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "0.1.0-alpha01"
      }
    })
    |> json_response(200)
    |> Map.fetch!("tokens")
  end

  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
