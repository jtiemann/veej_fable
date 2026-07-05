defmodule VeejrWeb.KeyGate do
  @moduledoc """
  LiveView `on_mount` hook that sends users without E2E keys to key setup.

  Mounted after `:require_authenticated` on every app view that deals with
  encrypted content.
  """
  use VeejrWeb, :verified_routes

  import Phoenix.LiveView

  def on_mount(:ensure_keys, _params, _session, socket) do
    if socket.assigns.current_scope.user.public_key do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: ~p"/keys")}
    end
  end
end
