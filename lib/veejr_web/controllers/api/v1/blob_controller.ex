defmodule VeejrWeb.Api.V1.BlobController do
  use VeejrWeb, :controller

  import Ecto.Query

  alias Veejr.Accounts.ApiIdempotencyKey
  alias Veejr.{Messaging, Repo}
  alias VeejrWeb.Api.V1.Response

  def create(conn, _params) do
    case read_body(conn, length: Messaging.max_blob_size()) do
      {:ok, body, conn} -> upload(conn, body)
      {:more, _partial, conn} -> too_large(conn)
      {:error, _reason} -> Response.error(conn, :bad_request, "invalid_body", "Upload failed.")
    end
  end

  defp upload(conn, body) do
    with {:ok, key} <- idempotency_key(conn) do
      user = conn.assigns.current_scope.user
      session = conn.assigns.api_device_session
      request_hash = :crypto.hash(:sha256, body)

      case process(user, session.id, key, request_hash, body) do
        {:ok, {:created, response}} ->
          conn |> put_status(:created) |> json(response)

        {:ok, {:replayed, response}} ->
          json(conn, response)

        {:ok, :conflict} ->
          Response.error(
            conn,
            :conflict,
            "idempotency_conflict",
            "The Idempotency-Key was already used for another request."
          )

        {:error, :too_large} ->
          too_large(conn)

        {:error, :storage_quota_exceeded} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "storage_quota_exceeded",
            "The instance attachment storage quota has been reached."
          )

        {:error, _reason} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "upload_failed",
            "The attachment could not be stored."
          )
      end
    else
      {:error, :invalid_idempotency_key} ->
        Response.error(
          conn,
          :bad_request,
          "invalid_request",
          "A valid Idempotency-Key is required."
        )
    end
  end

  defp process(user, session_id, key, request_hash, body) do
    Repo.transaction(
      fn -> process_locked(user, session_id, key, request_hash, body) end,
      mode: :immediate
    )
  end

  defp process_locked(user, session_id, key, request_hash, body) do
    case existing(session_id, key) do
      %ApiIdempotencyKey{request_hash: ^request_hash, response: response} ->
        {:replayed, response}

      %ApiIdempotencyKey{} ->
        :conflict

      nil ->
        case Messaging.create_blob(user, body) do
          {:ok, blob} ->
            response = %{id: blob.public_id, size: blob.size}

            %ApiIdempotencyKey{
              api_device_session_id: session_id,
              operation: "blob_upload",
              key: key,
              request_hash: request_hash,
              response: response
            }
            |> Repo.insert!()

            {:created, response}

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  defp existing(session_id, key) do
    Repo.one(
      from i in ApiIdempotencyKey,
        where:
          i.api_device_session_id == ^session_id and i.operation == "blob_upload" and
            i.key == ^key
    )
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) >= 22 and byte_size(key) <= 200 -> {:ok, key}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp too_large(conn) do
    Response.error(
      conn,
      :request_entity_too_large,
      "attachment_too_large",
      "The encrypted attachment is too large."
    )
  end
end
