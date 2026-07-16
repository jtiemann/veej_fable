defmodule VeejrWeb.BlobController do
  @moduledoc """
  Upload/download for attachment blobs.

  Bodies are already encrypted in the browser (XSalsa20-Poly1305 with a
  per-attachment key that travels inside the message envelope), so the server
  only ever shuttles opaque bytes.
  """
  use VeejrWeb, :controller

  alias Veejr.Messaging

  def create(conn, _params) do
    user = conn.assigns.current_scope.user

    case read_body(conn, length: Messaging.max_blob_size()) do
      {:ok, body, conn} ->
        case Messaging.create_blob(user, body) do
          {:ok, blob} ->
            json(conn, %{id: blob.public_id, size: blob.size})

          {:error, :too_large} ->
            conn
            |> put_status(:request_entity_too_large)
            |> json(%{error: "attachment too large"})

          {:error, :storage_quota_exceeded} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "instance attachment storage quota reached"})

          {:error, _} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "upload failed"})
        end

      {:more, _partial, conn} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "attachment too large"})
    end
  end

  def show(conn, %{"id" => id}) do
    case Messaging.get_blob(id) do
      nil ->
        send_resp(conn, :not_found, "not found")

      blob ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> send_file(200, blob.path)
    end
  end

  @doc """
  Public capability endpoint for cross-instance attachment downloads.

  An attachment uploaded on the sender's instance must be fetchable by a
  recipient whose session lives on a *different* instance. Like the envelope
  capability endpoint, the unguessable blob id is the credential and the
  bytes are E2E-encrypted (the symmetric key travels only inside the message
  payload), so this is served without a session and with permissive CORS.
  """
  def public_show(conn, %{"id" => id}) do
    conn = put_resp_header(conn, "access-control-allow-origin", "*")

    case Messaging.get_blob(id) do
      nil ->
        send_resp(conn, :not_found, "not found")

      blob ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_file(200, blob.path)
    end
  end
end
