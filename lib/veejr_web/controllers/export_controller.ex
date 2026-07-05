defmodule VeejrWeb.ExportController do
  use VeejrWeb, :controller

  def download(conn, _params) do
    user = conn.assigns.current_scope.user
    {:ok, filename, zip_binary} = Veejr.Export.build(user)

    send_download(conn, {:binary, zip_binary},
      filename: filename,
      content_type: "application/zip"
    )
  end
end
