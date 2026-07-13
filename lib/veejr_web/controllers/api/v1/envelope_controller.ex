defmodule VeejrWeb.Api.V1.EnvelopeController do
  use VeejrWeb, :controller

  alias Veejr.Messaging
  alias Veejr.Social.Address
  alias VeejrWeb.Api.V1.Response

  @page_size 50

  def index(conn, params) do
    user = conn.assigns.current_scope.user

    with {:ok, kind} <- kind(params["kind"]),
         {:ok, before_id} <- cursor_id(user, params["cursor"]) do
      envelopes =
        Messaging.list_history(user, kind: kind, before_id: before_id, limit: @page_size + 1)

      {page, next_cursor} = page(envelopes)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        envelopes: Enum.map(page, &render_envelope(&1, user)),
        next_cursor: next_cursor
      })
    else
      {:error, :kind} -> invalid_kind(conn)
      {:error, :cursor} -> invalid_cursor(conn)
    end
  end

  defp kind(nil), do: {:ok, nil}
  defp kind(kind) when kind in ~w(message location note), do: {:ok, kind}
  defp kind(_kind), do: {:error, :kind}

  defp cursor_id(_user, nil), do: {:ok, nil}

  defp cursor_id(user, cursor) when is_binary(cursor) do
    case Messaging.history_cursor_id(user, cursor) do
      nil -> {:error, :cursor}
      id -> {:ok, id}
    end
  end

  defp cursor_id(_user, _cursor), do: {:error, :cursor}

  defp page(envelopes) do
    if length(envelopes) > @page_size do
      page = Enum.take(envelopes, @page_size)
      {page, List.last(page).public_id}
    else
      {envelopes, nil}
    end
  end

  defp render_envelope(envelope, user) do
    %{
      public_id: envelope.public_id,
      batch_id: envelope.batch_id,
      kind: envelope.kind,
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      peer_key: Messaging.peer_key(envelope, user),
      sender: %{id: to_string(envelope.sender.id), handle: Address.handle(envelope.sender)},
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

  defp invalid_cursor(conn) do
    Response.error(conn, :bad_request, "invalid_cursor", "The history cursor is not valid.")
  end

  defp invalid_kind(conn) do
    Response.error(conn, :bad_request, "invalid_kind", "The envelope kind is not valid.")
  end
end
