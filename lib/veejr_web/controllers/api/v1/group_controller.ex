defmodule VeejrWeb.Api.V1.GroupController do
  use VeejrWeb, :controller

  alias Veejr.Social
  alias Veejr.Social.Address

  def index(conn, _params) do
    groups =
      conn.assigns.current_scope.user
      |> Social.list_groups()
      |> Enum.map(&render_group/1)

    json(conn, %{groups: groups})
  end

  defp render_group(group) do
    %{
      id: to_string(group.id),
      name: group.name,
      members:
        Enum.map(group.members, fn member ->
          %{id: to_string(member.id), handle: Address.handle(member)}
        end)
    }
  end
end
