defmodule VeejrWeb.FriendsLive do
  use VeejrWeb, :live_view

  alias Veejr.Social

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <.header>
        Friends
        <:subtitle>
          People you exchange encrypted messages with. Your address:
          <code>{Veejr.Social.Address.full(@current_scope.user)}</code>
        </:subtitle>
        <:actions>
          <.link navigate={~p"/groups"} class="btn btn-ghost btn-sm">Manage groups</.link>
        </:actions>
      </.header>

      <form phx-submit="add_friend" class="mt-6 flex gap-2">
        <input
          type="text"
          name="username"
          value={@add_username}
          placeholder="username, or user@host once federation lands"
          class="input flex-1"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-primary">Send request</button>
      </form>

      <section :if={@incoming != []} class="mt-8">
        <h2 class="text-lg font-semibold">Incoming requests</h2>
        <ul class="mt-2 space-y-2">
          <li
            :for={req <- @incoming}
            class="flex items-center justify-between rounded-lg border border-base-300 p-3"
          >
            <span>
              <span class="font-medium">{req.requester.display_name || req.requester.username}</span>
              <span class="opacity-60">@{req.requester.username}</span>
            </span>
            <span class="flex gap-2">
              <button phx-click="accept" phx-value-id={req.id} class="btn btn-primary btn-sm">
                Accept
              </button>
              <button phx-click="decline" phx-value-id={req.id} class="btn btn-ghost btn-sm">
                Decline
              </button>
            </span>
          </li>
        </ul>
      </section>

      <section :if={@outgoing != []} class="mt-8">
        <h2 class="text-lg font-semibold">Waiting on</h2>
        <ul class="mt-2 space-y-1">
          <li :for={req <- @outgoing} class="text-sm opacity-70">
            @{req.addressee.username} — request sent
          </li>
        </ul>
      </section>

      <section class="mt-8">
        <h2 class="text-lg font-semibold">Your friends</h2>
        <p :if={@friends == []} class="mt-2 text-sm opacity-60">
          No friends yet. Send a request above — you need their username.
        </p>
        <ul class="mt-2 space-y-2">
          <li
            :for={friend <- @friends}
            class="flex items-center justify-between rounded-lg border border-base-300 p-3"
          >
            <span>
              <span class="font-medium">{friend.display_name || friend.username}</span>
              <span class="opacity-60">@{friend.username}</span>
              <span :if={!friend.public_key} class="badge badge-warning badge-sm ml-2">
                no keys yet
              </span>
            </span>
            <button
              phx-click="remove"
              phx-value-id={friend.id}
              data-confirm="Remove this friend? They will also be removed from your groups."
              class="btn btn-ghost btn-sm"
            >
              Remove
            </button>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(add_username: "", page_title: "Friends") |> refresh()}
  end

  @impl true
  def handle_event("add_friend", %{"username" => input}, socket) do
    case Veejr.Social.Address.parse(input) do
      {:local, username} ->
        {:noreply, socket |> add_local_friend(username) |> assign(add_username: "") |> refresh()}

      {:remote, username, host} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "@#{username}@#{host} lives on another instance. Instance-to-instance " <>
             "friendships are on the roadmap — for now both accounts must be on this server."
         )}

      {:error, :invalid} ->
        {:noreply,
         put_flash(socket, :error, "That doesn't look like a username or user@host address.")}
    end
  end

  def handle_event("accept", %{"id" => id}, socket) do
    case Social.accept_friend_request(socket.assigns.current_scope.user, id) do
      {:ok, fr} ->
        {:noreply,
         socket
         |> put_flash(:info, "You and @#{fr.requester.username} are now friends!")
         |> refresh()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Request no longer exists.") |> refresh()}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    Social.decline_friend_request(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Social.remove_friend(socket.assigns.current_scope.user, String.to_integer(id))
    {:noreply, socket |> put_flash(:info, "Friend removed.") |> refresh()}
  end

  defp add_local_friend(socket, username) do
    case Social.send_friend_request(socket.assigns.current_scope.user, username) do
      {:ok, %Veejr.Social.Friendship{status: "accepted"}} ->
        put_flash(socket, :info, "You and @#{username} are now friends!")

      {:ok, _} ->
        put_flash(socket, :info, "Request sent to @#{username}.")

      {:error, :not_found} ->
        put_flash(socket, :error, "No user named @#{username} here.")

      {:error, :self} ->
        put_flash(socket, :error, "That's you.")

      {:error, :already_friends} ->
        put_flash(socket, :error, "You are already friends with @#{username}.")

      {:error, :already_requested} ->
        put_flash(socket, :error, "Request to @#{username} is already pending.")

      {:error, _} ->
        put_flash(socket, :error, "Could not send request.")
    end
  end

  defp refresh(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      friends: Social.list_friends(user),
      incoming: Social.list_incoming_requests(user),
      outgoing: Social.list_outgoing_requests(user)
    )
  end
end
