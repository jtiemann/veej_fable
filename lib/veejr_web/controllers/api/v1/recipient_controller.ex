defmodule VeejrWeb.Api.V1.RecipientController do
  use VeejrWeb, :controller

  alias Veejr.Social
  alias Veejr.Social.Address
  alias VeejrWeb.RecipientResolver

  def index(conn, _params) do
    contacts =
      conn.assigns.current_scope.user
      |> Social.list_friends()
      |> Enum.map(&render_recipient/1)

    json(conn, %{contacts: contacts})
  end

  def resolve(conn, params) do
    json(conn, RecipientResolver.resolve(conn.assigns.current_scope.user, params))
  end

  defp render_recipient(user) do
    %{
      id: to_string(user.id),
      username: user.username,
      handle: Address.handle(user),
      public_key: user.public_key
    }
  end
end
