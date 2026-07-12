defmodule VeejrWeb.Api.V1.MeController do
  use VeejrWeb, :controller

  alias VeejrWeb.Api.V1.AccountJSON

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{account: AccountJSON.render(conn.assigns.current_scope.user)})
  end
end
