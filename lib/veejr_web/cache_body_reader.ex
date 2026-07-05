defmodule VeejrWeb.CacheBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers` that stashes the raw request bytes in
  `conn.assigns.raw_body`, so signature verification can hash exactly what
  was sent (re-encoding parsed JSON is not byte-stable).
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      {:more, body, conn} ->
        {:more, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      other ->
        other
    end
  end
end
