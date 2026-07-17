defmodule VeejrWeb.ProvisionerAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> candidate] ->
        if Veejr.AccountMoves.secure_token?(candidate),
          do: conn,
          else: reject(conn, 401, "unauthorized")

      _ ->
        status = if Veejr.AccountMoves.enabled?(), do: 401, else: 503
        error = if status == 503, do: "provisioner_disabled", else: "unauthorized"
        reject(conn, status, error)
    end
  end

  defp reject(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
