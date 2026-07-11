defmodule VeejrWeb.PageController do
  use VeejrWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/contacts")
    else
      render(conn, :home)
    end
  end
end
