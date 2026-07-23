defmodule VeejrWeb.GuestConferenceLive.HostCall do
  use VeejrWeb, :live_view

  alias Veejr.{Calls, GuestConferences}

  @impl true
  def render(assigns), do: VeejrWeb.CallLive.render(assigns)

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    host = socket.assigns.current_scope.user

    with {:ok, conference} <- GuestConferences.get_for_host(host, public_id),
         call when not is_nil(call) <- conference.call,
         true <- call.state in ["ringing", "accepted"] do
      if connected?(socket) do
        Calls.subscribe(call)
        Calls.register_presence(call.public_id, host.id)

        if call.state == "accepted" do
          send(self(), {:call_peer_joined, call.public_id})
        end
      end

      {:ok,
       assign(socket,
         page_title: "Guest call",
         call: call,
         role: "caller",
         peer: guest_peer(conference),
         actor: host,
         layout_scope: socket.assigns.current_scope,
         is_guest: false,
         allow_reinvite: false,
         conference: conference,
         return_to: ~p"/guest-conferences/#{public_id}",
         ice_servers: Jason.encode!(Veejr.Calls.IceConfig.servers())
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That guest call is no longer available.")
         |> push_navigate(to: ~p"/guest-conferences/#{public_id}", replace: true)}
    end
  end

  @impl true
  def handle_event("signal", %{"ciphertext" => ciphertext, "nonce" => nonce}, socket) do
    Calls.signal_guest_host(
      socket.assigns.current_scope.user,
      socket.assigns.call,
      ciphertext,
      nonce
    )

    {:noreply, socket}
  end

  def handle_event("hangup", _params, socket) do
    Calls.end_guest_host_call(socket.assigns.current_scope.user, socket.assigns.call)
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:call_peer_joined, _id}, socket) do
    {:noreply, push_event(socket, "call:peer_joined", %{})}
  end

  def handle_info({:call_signal, _id, from_id, ciphertext, nonce}, socket) do
    if from_id == socket.assigns.current_scope.user.id do
      {:noreply, socket}
    else
      {:noreply, push_event(socket, "call:signal", %{ciphertext: ciphertext, nonce: nonce})}
    end
  end

  def handle_info({:call_ended, _id, _reason}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_info({:call_disconnected, _id, _departed}, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to, replace: true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if call = socket.assigns[:call] do
      Calls.end_guest_host_call_after_grace(
        socket.assigns.current_scope.user,
        call
      )
    end

    :ok
  end

  defp guest_peer(conference) do
    %{
      id: "guest-#{conference.id}",
      username: conference.display_name,
      display_name: conference.display_name,
      public_key: conference.public_key
    }
  end
end
