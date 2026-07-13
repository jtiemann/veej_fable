defmodule VeejrWeb.Api.V1.GroupController do
  use VeejrWeb, :controller

  alias Veejr.Social
  alias Veejr.Social.Address

  def index(conn, _params) do
    owner = conn.assigns.current_scope.user
    notes = Social.list_group_notes(owner)

    groups =
      owner
      |> Social.list_groups()
      |> Enum.map(&render_group(&1, notes))

    json(conn, %{groups: groups})
  end

  def note(conn, %{"id" => id, "body" => body}) do
    case Social.upsert_group_note(conn.assigns.current_scope.user, id, body) do
      {:ok, note} -> json(conn, %{note: %{subject_id: to_string(note.group_id), body: note.body}})
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp render_group(group, notes) do
    %{
      id: to_string(group.id),
      name: group.name,
      note: Map.get(notes, group.id, ""),
      members:
        Enum.map(group.members, fn member ->
          %{id: to_string(member.id), handle: Address.handle(member)}
        end)
    }
  end

  defp not_found(conn) do
    VeejrWeb.Api.V1.Response.error(conn, :not_found, "not_found", "The group was not found.")
  end
end
