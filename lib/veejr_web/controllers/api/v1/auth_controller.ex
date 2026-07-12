defmodule VeejrWeb.Api.V1.AuthController do
  use VeejrWeb, :controller

  alias Veejr.Accounts
  alias VeejrWeb.Api.V1.{AccountJSON, Response}

  def login(conn, %{"email" => email, "password" => password, "device" => device})
      when is_map(device) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        invalid_credentials(conn)

      user ->
        case Accounts.create_api_device_session(user, device) do
          {:ok, _session, tokens} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> json(%{account: AccountJSON.render(user), tokens: tokens})

          {:error, changeset} ->
            Response.error(
              conn,
              :unprocessable_entity,
              "validation_failed",
              "The request is invalid.",
              %{
                fields: translate_errors(changeset)
              }
            )
        end
    end
  end

  def login(conn, _params),
    do: Response.error(conn, :bad_request, "invalid_request", "The request is invalid.")

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Accounts.rotate_api_device_session(refresh_token) do
      {:ok, {_session, tokens}} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{tokens: tokens})

      {:error, _reason} ->
        Response.error(
          conn,
          :unauthorized,
          "invalid_refresh_token",
          "The refresh token is invalid."
        )
    end
  end

  def refresh(conn, _params),
    do: Response.error(conn, :bad_request, "invalid_request", "The request is invalid.")

  def logout(conn, _params) do
    scope = conn.assigns.current_scope
    session = conn.assigns.api_device_session
    :ok = Accounts.delete_api_device_session(scope, session.id)
    send_resp(conn, :no_content, "")
  end

  defp invalid_credentials(conn) do
    Response.error(conn, :unauthorized, "invalid_credentials", "Invalid email or password.")
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
