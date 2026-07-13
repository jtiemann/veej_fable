defmodule VeejrWeb.Api.V1.RecipientController do
  use VeejrWeb, :controller

  alias Veejr.{Messaging, Social}
  alias Veejr.Social.Address
  alias VeejrWeb.RecipientResolver

  def index(conn, _params) do
    owner = conn.assigns.current_scope.user
    notes = Social.list_contact_notes(owner)

    contacts =
      owner
      |> Social.list_friends()
      |> Enum.map(&render_recipient(owner, &1, notes))

    json(conn, %{contacts: contacts})
  end

  def resolve(conn, params) do
    json(conn, RecipientResolver.resolve(conn.assigns.current_scope.user, params))
  end

  def note(conn, %{"id" => id, "body" => body}) do
    case Social.upsert_contact_note(conn.assigns.current_scope.user, id, body) do
      {:ok, note} ->
        json(conn, %{note: %{subject_id: to_string(note.contact_id), body: note.body}})

      {:error, :not_a_friend} ->
        not_found(conn)
    end
  end

  defp render_recipient(owner, user, notes) do
    %{
      id: to_string(user.id),
      username: user.username,
      handle: Address.handle(user),
      public_key: user.public_key,
      auto_accept: Messaging.automatic_delivery?(owner, user),
      note: Map.get(notes, user.id, "")
    }
  end

  defp not_found(conn) do
    VeejrWeb.Api.V1.Response.error(conn, :not_found, "not_found", "The contact was not found.")
  end
end
