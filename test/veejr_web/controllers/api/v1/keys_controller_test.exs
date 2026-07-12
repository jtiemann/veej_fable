defmodule VeejrWeb.Api.V1.KeysControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  describe "PUT /api/v1/keys" do
    setup %{conn: conn} do
      user = user_fixture() |> set_password()

      tokens =
        conn
        |> post("/api/v1/auth/login", login_params(user))
        |> json_response(200)
        |> Map.fetch!("tokens")

      %{user: user, tokens: tokens}
    end

    test "stores validated portable key material", %{conn: conn, tokens: tokens} do
      response =
        conn
        |> authorize(tokens["access_token"])
        |> put("/api/v1/keys", key_params())
        |> json_response(201)

      assert response["account"]["keys_configured"]
      assert response["account"]["public_key"] == key_params()["public_key"]
      assert response["account"]["wrapped_key"] == key_params()["wrapped_key"]
    end

    test "rejects malformed or incorrectly sized key material", %{conn: conn, tokens: tokens} do
      params = put_in(key_params(), ["wrapped_key", "salt"], Base.encode64(<<1, 2>>))

      response =
        conn
        |> authorize(tokens["access_token"])
        |> put("/api/v1/keys", params)
        |> json_response(422)

      assert response["error"]["code"] == "validation_failed"
    end

    test "does not overwrite an existing identity", %{conn: conn, tokens: tokens} do
      conn
      |> authorize(tokens["access_token"])
      |> put("/api/v1/keys", key_params())
      |> json_response(201)

      response =
        build_conn()
        |> authorize(tokens["access_token"])
        |> put("/api/v1/keys", key_params())
        |> json_response(409)

      assert response["error"]["code"] == "keys_already_configured"
    end

    test "requires a device access token", %{conn: conn} do
      response = conn |> put("/api/v1/keys", key_params()) |> json_response(401)
      assert response["error"]["code"] == "authentication_required"
    end
  end

  defp key_params do
    %{
      "public_key" => Base.encode64(:binary.copy(<<1>>, 32)),
      "wrapped_key" => %{
        "ciphertext" => Base.encode64(:binary.copy(<<2>>, 48)),
        "salt" => Base.encode64(:binary.copy(<<3>>, 16)),
        "nonce" => Base.encode64(:binary.copy(<<4>>, 24)),
        "kdf" => %{"name" => "PBKDF2-SHA256", "iterations" => 310_000},
        "wrap" => "XSalsa20-Poly1305"
      }
    }
  end

  defp login_params(user) do
    %{
      "email" => user.email,
      "password" => valid_user_password(),
      "device" => %{
        "name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "0.1.0-alpha01"
      }
    }
  end

  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
