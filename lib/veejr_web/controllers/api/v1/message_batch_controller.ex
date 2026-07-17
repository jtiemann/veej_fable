defmodule VeejrWeb.Api.V1.MessageBatchController do
  use VeejrWeb, :controller

  import Ecto.Query

  alias Veejr.Accounts.ApiIdempotencyKey
  alias Veejr.{Messaging, Repo}
  alias VeejrWeb.Api.V1.Response

  def create(conn, %{"kind" => "message", "envelopes" => envelopes} = params)
      when is_list(envelopes) do
    user = conn.assigns.current_scope.user
    session = conn.assigns.api_device_session

    with {:ok, key} <- idempotency_key(conn),
         :ok <- validate_envelopes(envelopes, user.id) do
      request_hash = :crypto.hash(:sha256, Jason.encode!(params))

      case process(user, session.id, key, request_hash, params, envelopes) do
        {:ok, {:replayed, response}} ->
          json(conn, response)

        {:ok, {:created, response}} ->
          :ok = Messaging.broadcast_batch_notifications(user, response.batch_id)
          conn |> put_status(:created) |> json(response)

        {:ok, :conflict} ->
          Response.error(
            conn,
            :conflict,
            "idempotency_conflict",
            "The idempotency key was already used for another request."
          )

        {:error, _reason} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "validation_failed",
            "The envelope batch is invalid."
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

      {:error, :invalid_envelopes} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "The envelope batch is invalid."
        )
    end
  end

  def create(conn, _params) do
    Response.error(
      conn,
      :unprocessable_entity,
      "validation_failed",
      "The message batch is invalid."
    )
  end

  defp process(user, session_id, key, request_hash, params, envelopes) do
    Repo.transaction(
      fn -> process_locked(user, session_id, key, request_hash, params, envelopes) end,
      mode: :immediate
    )
  end

  defp process_locked(user, session_id, key, request_hash, params, envelopes) do
    case existing(session_id, key) do
      %ApiIdempotencyKey{request_hash: ^request_hash, response: response} ->
        {:replayed, response}

      %ApiIdempotencyKey{} ->
        :conflict

      nil ->
        opts = [
          expires_at: params["expires_at"],
          max_displays: params["max_displays"],
          attachment_ids: params["attachment_ids"],
          defer_notifications: true
        ]

        case Messaging.send_batch(user, "message", envelopes, opts) do
          {:ok, batch_id, queued} ->
            response = %{
              batch_id: batch_id,
              copies:
                user
                |> Messaging.list_batch_copies(batch_id)
                |> Enum.map(&Map.update!(&1, :recipient_id, fn id -> to_string(id) end)),
              queued_recipients: queued
            }

            %ApiIdempotencyKey{
              api_device_session_id: session_id,
              operation: "message_batch",
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
          i.api_device_session_id == ^session_id and i.operation == "message_batch" and
            i.key == ^key
    )
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) >= 22 and byte_size(key) <= 200 -> {:ok, key}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp validate_envelopes(envelopes, user_id) do
    ids = Enum.map(envelopes, &to_string(&1["recipient_id"]))

    if envelopes != [] and Enum.count(ids, &(&1 == to_string(user_id))) == 1 and
         length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      {:error, :invalid_envelopes}
    end
  end
end
