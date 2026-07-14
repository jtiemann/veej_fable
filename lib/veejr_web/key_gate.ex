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
      return_to = socket |> get_connect_info(:uri) |> path_from_uri()
      {:halt, redirect(socket, to: ~p"/keys?return_to=#{return_to}")}
    end
  end

  defp path_from_uri(%URI{path: path, query: query, fragment: fragment}) when is_binary(path) do
    URI.to_string(%URI{path: path, query: query, fragment: fragment})
  end

  defp path_from_uri(_uri), do: "/"
end
