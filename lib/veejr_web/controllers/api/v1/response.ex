defmodule VeejrWeb.Api.V1.Response do
  import Plug.Conn
  import Phoenix.Controller

  def error(conn, status, code, message, details \\ %{}) do
    request_id = get_resp_header(conn, "x-request-id") |> List.first()

    body = %{
      error: %{
        code: code,
        message: message,
        request_id: request_id,
        details: details
      }
    }

    conn
    |> put_status(status)
    |> json(body)
  end
end
