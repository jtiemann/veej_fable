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

  alias Veejr.Messaging

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket), do: Messaging.subscribe(user)

    socket =
      socket
      |> assign(:pending_count, Messaging.count_pending_notifications(user))
      |> attach_hook(:veejr_notify, :handle_info, &handle_info/2)

    {:cont, socket}
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
end
