defmodule VeejrWeb.PushController do
  use VeejrWeb, :controller

  alias Veejr.Push

  def create(conn, params) do
    case Push.subscribe(conn.assigns.current_scope.user, params) do
      {:ok, _} ->
        json(conn, %{ok: true})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid subscription"})
    end
  end

  def delete(conn, %{"endpoint" => endpoint}) do
    Push.unsubscribe(conn.assigns.current_scope.user, endpoint)
    json(conn, %{ok: true})
  end
end
