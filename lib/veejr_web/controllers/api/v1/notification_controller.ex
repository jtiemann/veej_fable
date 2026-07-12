defmodule VeejrWeb.Api.V1.NotificationController do
  use VeejrWeb, :controller

  alias Veejr.Messaging
  alias Veejr.Social.Address
  alias VeejrWeb.Api.V1.Response

  def index(conn, %{"state" => "pending"}) do
    notifications =
      conn.assigns.current_scope.user
      |> Messaging.list_pending_notifications()
      |> Enum.map(&render_notification/1)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{notifications: notifications})
  end

  def index(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "invalid_request",
      "Only pending notifications are supported."
    )
  end

  def accept(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with {:ok, notification} <- Messaging.accept_notification(user, id),
         {:ok, envelope} <- Messaging.fetch_envelope(user, notification.envelope.public_id) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{envelope: render_envelope(envelope, user)})
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, :origin_unreachable} ->
        Response.error(
          conn,
          :bad_gateway,
          "origin_unreachable",
          "The sender's instance could not be reached."
        )

      {:error, :unauthorized} ->
        not_found(conn)
    end
  end

  def decline(conn, %{"id" => id}) do
    case Messaging.decline_notification(conn.assigns.current_scope.user, id) do
      {:ok, _notification} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp render_notification(notification) do
    envelope = notification.envelope

    %{
      id: to_string(notification.id),
      kind: envelope.kind,
      sender: render_sender(envelope.sender),
      created_at: notification.inserted_at,
      expires_at: envelope.expires_at,
      max_displays: envelope.max_displays
    }
  end

  defp render_envelope(envelope, user) do
    %{
      public_id: envelope.public_id,
      batch_id: envelope.batch_id,
      kind: envelope.kind,
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      peer_key: Messaging.peer_key(envelope, user),
      sender: render_sender(envelope.sender),
      sent_by_me: envelope.sender_id == user.id,
      resealed: envelope.resealed,
      created_at: envelope.inserted_at,
      edited_at: envelope.edited_at,
      delivered_at: envelope.delivered_at,
      expires_at: envelope.expires_at,
      max_displays: envelope.max_displays,
      display_count: envelope.display_count
    }
  end

  defp render_sender(sender), do: %{id: to_string(sender.id), handle: Address.handle(sender)}

  defp not_found(conn) do
    Response.error(conn, :not_found, "not_found", "The notification was not found.")
  end
end
