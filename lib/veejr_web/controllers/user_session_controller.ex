defmodule VeejrWeb.UserSessionController do
  use VeejrWeb, :controller

  alias Veejr.Accounts
  alias VeejrWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params} = params, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, login_params(user_params, params))

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: login_path(params["return_to"]))
    end
  end

  # email + password login
  defp create(conn, %{"user" => %{"email" => email} = user_params} = params, info) do
    create(
      conn,
      Map.put(params, "user", user_params |> Map.delete("email") |> Map.put("identifier", email)),
      info
    )
  end

  defp create(conn, %{"user" => user_params} = params, info) do
    %{"identifier" => identifier, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(identifier, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, login_params(user_params, params))
    else
      # In order to prevent user enumeration attacks, don't disclose whether the identifier is registered.
      conn
      |> put_flash(:error, "Invalid username, email, or password")
      |> put_flash(:identifier, String.slice(identifier, 0, 160))
      |> redirect(to: login_path(params["return_to"]))
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  defp login_params(user_params, params) do
    Map.put(user_params, "return_to", UserAuth.local_return_to(params["return_to"]))
  end

  defp login_path(return_to) do
    case UserAuth.local_return_to(return_to) do
      nil -> ~p"/users/log-in"
      path -> ~p"/users/log-in?#{[return_to: path]}"
    end
  end
end
