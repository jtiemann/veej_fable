defmodule VeejrWeb.Api.V1.KeysController do
  use VeejrWeb, :controller

  alias Veejr.Accounts
  alias VeejrWeb.Api.V1.{AccountJSON, Response}

  def create(
        conn,
        %{
          "public_key" => public_key,
          "wrapped_key" => %{
            "ciphertext" => ciphertext,
            "salt" => salt,
            "nonce" => nonce,
            "kdf" => %{"name" => "PBKDF2-SHA256", "iterations" => 310_000},
            "wrap" => "XSalsa20-Poly1305"
          }
        }
      ) do
    with :ok <- validate_base64(public_key, 32),
         :ok <- validate_base64(ciphertext, 48),
         :ok <- validate_base64(salt, 16),
         :ok <- validate_base64(nonce, 24),
         {:ok, user} <-
           Accounts.setup_user_keys(conn.assigns.current_scope.user, %{
             public_key: public_key,
             enc_secret_key: ciphertext,
             key_salt: salt,
             key_nonce: nonce
           }) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:created)
      |> json(%{account: AccountJSON.render(user)})
    else
      {:error, :invalid_key_material} ->
        invalid_key_material(conn)

      {:error, :keys_already_set} ->
        Response.error(
          conn,
          :conflict,
          "keys_already_configured",
          "Identity keys are already configured."
        )

      {:error, %Ecto.Changeset{}} ->
        invalid_key_material(conn)
    end
  end

  def create(conn, _params), do: invalid_key_material(conn)

  defp validate_base64(value, byte_count) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) == byte_count -> :ok
      _ -> {:error, :invalid_key_material}
    end
  end

  defp validate_base64(_, _), do: {:error, :invalid_key_material}

  defp invalid_key_material(conn) do
    Response.error(
      conn,
      :unprocessable_entity,
      "validation_failed",
      "The supplied key material is invalid."
    )
  end
end
