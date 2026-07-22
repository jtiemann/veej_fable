defmodule VeejrWeb.LiveNotify do
  @moduledoc """
  Shared live-notification plumbing for app views.

  Subscribes the LiveView to the user's PubSub topic, keeps the
  `@pending_count` badge current, and pushes a `veejr:notify` event to the
  browser (which surfaces it via the Notification API) whenever an encrypted
  item arrives. Views that define their own `handle_info/2` still receive the
  message afterwards so they can refresh their lists.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Veejr.{Messaging, WatchParties}

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      Messaging.subscribe(user)
      WatchParties.subscribe()
    end

    socket =
      socket
      |> assign(:pending_count, Messaging.count_pending_notifications(user))
      |> attach_hook(:veejr_notify, :handle_info, &handle_info/2)

    socket =
      if connected?(socket) do
        case WatchParties.active_party() do
          nil -> socket
          party -> push_watch_invite(socket, party)
        end
      else
        socket
      end

    {:cont, socket}
  end

  defp handle_info({:veejr_call_ring, call}, socket) do
    socket =
      push_event(socket, "veejr:ring", %{
        call_id: call.public_id,
        from: Veejr.Social.Address.handle(call.caller)
      })

    {:halt, socket}
  end

  defp handle_info({:watch_party_started, party}, socket) do
    {:halt, push_watch_invite(socket, party)}
  end

  defp handle_info({:watch_party_ended, public_id}, socket) do
    socket = push_event(socket, "watch:ended", %{public_id: public_id})

    if socket.view == VeejrWeb.WatchLive do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:veejr_notification, notification}, socket) do
    socket =
      socket
      |> assign(
        :pending_count,
        Messaging.count_pending_notifications(socket.assigns.current_scope.user)
      )
      |> push_event("veejr:notify", %{
        from: notification.envelope.sender.username,
        kind: notification.envelope.kind
      })

    # Views with their own handle_info get the message too; others stop here.
    if function_exported?(socket.view, :handle_info, 2) do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp push_watch_invite(socket, party) do
    push_event(socket, "watch:invite", %{public_id: party.public_id, host: party.host})
  end
end
