defmodule VeejrWeb.Api.V1.AuthController do
  use VeejrWeb, :controller

  alias Veejr.Accounts
  alias VeejrWeb.Api.V1.{AccountJSON, Response}

  def login(conn, %{"identifier" => identifier, "password" => password, "device" => device})
      when is_map(device) do
    case Accounts.get_user_by_email_and_password(identifier, password) do
      nil ->
        invalid_credentials(conn)

      user ->
        case Accounts.create_api_device_session(user, device) do
          {:ok, _session, tokens} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> json(%{account: AccountJSON.render(user), tokens: tokens})

          {:error, :suspended} ->
            invalid_credentials(conn)

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

  # Keep existing Android releases working while they migrate to the more
  # flexible `identifier` field.
  def login(conn, %{"email" => email} = params) do
    login(conn, params |> Map.delete("email") |> Map.put("identifier", email))
  end

  def login(conn, _params),
    do: Response.error(conn, :bad_request, "invalid_request", "The request is invalid.")

  # Requesting a one-time login token is deliberately non-enumerating. The
  # Android client can extract the token from its App Link and exchange it for
  # a native device session without ever handling a browser cookie.
  def request_magic_link(conn, %{"identifier" => identifier}) when is_binary(identifier) do
    if user = Accounts.get_user_by_login_identifier(identifier) do
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:accepted)
    |> json(%{})
  end

  def request_magic_link(conn, %{"email" => email} = params) do
    request_magic_link(conn, params |> Map.delete("email") |> Map.put("identifier", email))
  end

  def request_magic_link(conn, _params),
    do: Response.error(conn, :bad_request, "invalid_request", "The request is invalid.")

  def exchange_magic_link(conn, %{"token" => token, "device" => device})
      when is_binary(token) and is_map(device) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        case Accounts.create_api_device_session(user, device) do
          {:ok, _session, tokens} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> json(%{account: AccountJSON.render(user), tokens: tokens})

          {:error, :suspended} ->
            invalid_one_time_token(conn)

          {:error, changeset} ->
            validation_failed(conn, changeset)
        end

      {:error, _reason} ->
        invalid_one_time_token(conn)
    end
  end

  def exchange_magic_link(conn, _params),
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

  def register_push_token(conn, %{"token" => token})
      when is_binary(token) and byte_size(token) <= 4_096 do
    case Veejr.Push.register_android_token(
           conn.assigns.current_scope.user,
           conn.assigns.api_device_session.id,
           token
         ) do
      :ok ->
        send_resp(conn, :no_content, "")

      _ ->
        Response.error(conn, :not_found, "device_not_found", "The device session was not found.")
    end
  end

  def register_push_token(conn, _params),
    do: Response.error(conn, :bad_request, "invalid_request", "The request is invalid.")

  def delete_push_token(conn, _params) do
    :ok =
      Veejr.Push.remove_android_token(
        conn.assigns.current_scope.user,
        conn.assigns.api_device_session.id
      )

    send_resp(conn, :no_content, "")
  end

  defp invalid_credentials(conn) do
    Response.error(
      conn,
      :unauthorized,
      "invalid_credentials",
      "Invalid username, email, or password."
    )
  end

  defp invalid_one_time_token(conn) do
    Response.error(
      conn,
      :unauthorized,
      "invalid_one_time_token",
      "The one-time login token is invalid or has expired."
    )
  end

  defp validation_failed(conn, changeset) do
    Response.error(
      conn,
      :unprocessable_entity,
      "validation_failed",
      "The request is invalid.",
      %{fields: translate_errors(changeset)}
    )
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
