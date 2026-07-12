defmodule VeejrWeb.ApiAuth do
  import Plug.Conn

  alias Veejr.Accounts
  alias Veejr.Accounts.Scope
  alias VeejrWeb.Api.V1.Response

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {user, session} <- Accounts.get_user_and_api_session_by_access_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> assign(:api_device_session, session)
    else
      _ ->
        conn
        |> Response.error(:unauthorized, "authentication_required", "Authentication is required.")
        |> halt()
    end
  end
end
