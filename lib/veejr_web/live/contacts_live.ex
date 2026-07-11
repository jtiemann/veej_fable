defmodule VeejrWeb.ContactsLive do
  use VeejrWeb, :live_view

  alias Veejr.{Messaging, Social}

  @conversation_limit 100

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-7xl space-y-6"
    >
      <.header>
        Contacts
        <:subtitle>
          Conversations, friends, and groups in one place. Your address:
          <code>{Social.Address.full(@current_scope.user)}</code>
        </:subtitle>
        <:actions>
          <.link navigate={~p"/messages"} class="btn btn-primary btn-sm">New message</.link>
        </:actions>
      </.header>

      <section :if={@pending != []} class="rounded-lg border border-primary/20 bg-primary/10 p-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <h2 class="text-sm font-semibold text-base-content">
              Waiting for you
              <span class="ml-1 rounded-full bg-primary px-2 py-0.5 text-xs text-primary-content">
                {length(@pending)}
              </span>
            </h2>
            <p class="text-xs opacity-70">Encrypted items need your approval.</p>
          </div>
          <.link navigate={~p"/messages"} class="btn btn-outline btn-sm">Messages</.link>
        </div>
        <ul class="mt-3 grid gap-2 lg:grid-cols-2">
          <li
            :for={notif <- @pending}
            class="flex items-center justify-between gap-3 rounded-lg border border-primary/20 bg-base-100 px-3 py-2"
          >
            <span class="min-w-0 text-sm text-base-content">
              <span class="font-medium">
                {Veejr.Social.Address.handle(notif.envelope.sender)}
              </span>
              sent an encrypted {notif.envelope.kind}
              <span class="text-xs opacity-70">
                - {Calendar.strftime(notif.inserted_at, "%b %d, %H:%M")} UTC
              </span>
            </span>
            <span class="flex shrink-0 gap-2">
              <button
                phx-click="request_notification"
                phx-value-id={notif.id}
                class="btn btn-primary btn-xs"
              >
                Request
              </button>
              <button
                phx-click="decline_notification"
                phx-value-id={notif.id}
                class="btn btn-ghost btn-xs"
              >
                Decline
              </button>
            </span>
          </li>
        </ul>
      </section>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(22rem,0.85fr)]">
        <section class="rounded-lg border border-base-300 bg-base-100 p-4">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold">Conversations</h2>
              <p class="text-sm opacity-70">Pick a thread to continue it in Messages.</p>
            </div>
            <.link navigate={~p"/messages"} class="btn btn-outline btn-sm">Compose</.link>
          </div>

          <p :if={@conversations == []} class="mt-4 text-sm opacity-60">
            No conversations yet.
          </p>

          <ul class="mt-4 divide-y divide-base-300">
            <li :for={conversation <- @conversations}>
              <.link
                navigate={~p"/messages?conversation=#{conversation.key}"}
                class="flex items-center justify-between gap-3 rounded-lg px-2 py-3 transition hover:bg-base-200"
              >
                <div class="min-w-0">
                  <p class="truncate font-medium">
                    {Enum.join(conversation.participants, ", ")}
                  </p>
                  <p class="text-xs opacity-70">
                    {length(conversation.envelopes)} messages · latest {Calendar.strftime(
                      conversation.latest.inserted_at,
                      "%b %d, %H:%M"
                    )} UTC
                  </p>
                </div>
                <span class="shrink-0 text-sm font-medium text-primary">Open</span>
              </.link>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-base-300 bg-base-100 p-4">
          <h2 class="text-lg font-semibold">Add Friend</h2>
          <p class="text-sm opacity-70">Use a local username or user@host from another instance.</p>
          <form phx-submit="add_friend" class="mt-4 flex flex-col gap-2 sm:flex-row">
            <input
              type="text"
              name="username"
              value={@add_username}
              placeholder="username or user@host"
              class="input flex-1"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary">Send request</button>
          </form>
        </section>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <section class="rounded-lg border border-base-300 bg-base-100 p-4">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">Friends</h2>
            <span class="badge badge-outline">{length(@friends)}</span>
          </div>

          <section :if={@key_changes != []} class="mt-4 rounded-lg border border-warning/50 p-3">
            <h3 class="font-semibold text-warning">Key changes need confirmation</h3>
            <ul class="mt-2 space-y-2">
              <li
                :for={friend <- @key_changes}
                class="flex items-center justify-between gap-3 text-sm"
              >
                <span class="min-w-0">
                  <span class="font-medium">{friend.display_name || friend.username}</span>
                  <span class="opacity-60">{Social.Address.handle(friend)}</span>
                </span>
                <button
                  phx-click="confirm_key"
                  phx-value-id={friend.id}
                  data-confirm="Accept this friend's new encryption key? Messages you send will be encrypted to it."
                  class="btn btn-warning btn-xs"
                >
                  Accept key
                </button>
              </li>
            </ul>
          </section>

          <section :if={@incoming != []} class="mt-4">
            <h3 class="text-sm font-semibold uppercase tracking-wide opacity-70">
              Incoming requests
            </h3>
            <ul class="mt-2 space-y-2">
              <li
                :for={req <- @incoming}
                class="flex items-center justify-between gap-3 rounded-lg border border-base-300 p-3"
              >
                <span class="min-w-0">
                  <span class="font-medium">{req.requester.display_name || req.requester.username}</span>
                  <span class="opacity-60">{Social.Address.handle(req.requester)}</span>
                </span>
                <span class="flex gap-2">
                  <button phx-click="accept" phx-value-id={req.id} class="btn btn-primary btn-xs">
                    Accept
                  </button>
                  <button phx-click="decline" phx-value-id={req.id} class="btn btn-ghost btn-xs">
                    Decline
                  </button>
                </span>
              </li>
            </ul>
          </section>

          <section :if={@outgoing != []} class="mt-4">
            <h3 class="text-sm font-semibold uppercase tracking-wide opacity-70">Waiting on</h3>
            <ul class="mt-2 space-y-1">
              <li :for={req <- @outgoing} class="text-sm opacity-70">
                {Social.Address.handle(req.addressee)} - request sent
              </li>
            </ul>
          </section>

          <p :if={@friends == []} class="mt-4 text-sm opacity-60">
            No friends yet. Send a request above to start sharing.
          </p>

          <ul class="mt-4 space-y-2">
            <li
              :for={friend <- @friends}
              class="rounded-lg border border-base-300 p-3"
            >
              <div class="flex items-start justify-between gap-3">
                <span class="min-w-0">
                  <span class="block truncate font-medium">{friend.display_name || friend.username}</span>
                  <span class="text-sm opacity-60">{Social.Address.handle(friend)}</span>
                  <span :if={friend.host} class="badge badge-info badge-sm ml-2">remote</span>
                  <span :if={!friend.public_key} class="badge badge-warning badge-sm ml-2">
                    no keys yet
                  </span>
                </span>
                <span class="flex shrink-0 gap-2">
                  <.link
                    navigate={~p"/messages?friend_id=#{friend.id}"}
                    class="btn btn-primary btn-sm"
                  >
                    Message
                  </.link>
                  <button
                    phx-click="remove"
                    phx-value-id={friend.id}
                    data-confirm="Remove this friend? They will also be removed from your groups."
                    class="btn btn-ghost btn-sm"
                  >
                    Remove
                  </button>
                </span>
              </div>

              <details class="collapse collapse-arrow mt-3 rounded-lg border border-base-300 bg-base-200">
                <summary class="collapse-title min-h-0 px-3 py-2 text-sm font-medium">
                  Personal info & notes
                </summary>
                <div class="collapse-content px-3 pb-3">
                  <form phx-submit="save_note">
                    <input type="hidden" name="contact_id" value={friend.id} />
                    <label class="text-xs font-semibold uppercase tracking-wide opacity-60">
                      Personal notes
                    </label>
                    <textarea
                      name="body"
                      rows="3"
                      maxlength="4000"
                      class="textarea textarea-bordered mt-1 w-full resize-y text-sm"
                      placeholder="Private notes about this contact"
                    >{Map.get(@contact_notes, friend.id, "")}</textarea>
                    <div class="mt-2 flex justify-end">
                      <button type="submit" class="btn btn-sm">Save note</button>
                    </div>
                  </form>
                </div>
              </details>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-base-300 bg-base-100 p-4">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">Groups</h2>
            <span class="badge badge-outline">{length(@groups)}</span>
          </div>
          <form phx-submit="create_group" class="mt-4 flex flex-col gap-2 sm:flex-row">
            <input
              type="text"
              name="name"
              placeholder="new group name"
              class="input flex-1"
              autocomplete="off"
              required
            />
            <button type="submit" class="btn btn-primary">Create</button>
          </form>

          <p :if={@groups == []} class="mt-4 text-sm opacity-60">
            No groups yet.
          </p>

          <div class="mt-4 space-y-4">
            <section :for={group <- @groups} class="rounded-lg border border-base-300 p-3">
              <div class="flex items-center justify-between gap-3">
                <div class="min-w-0">
                  <h3 class="truncate font-semibold">{group.name}</h3>
                  <p class="text-sm opacity-60">{length(group.members)} members</p>
                </div>
                <span class="flex shrink-0 gap-2">
                  <.link navigate={~p"/messages?group_id=#{group.id}"} class="btn btn-primary btn-sm">
                    Message
                  </.link>
                  <button
                    phx-click="delete_group"
                    phx-value-id={group.id}
                    data-confirm={"Delete group \"#{group.name}\"? Friends stay friends."}
                    class="btn btn-ghost btn-sm"
                  >
                    Delete
                  </button>
                </span>
              </div>

              <div class="mt-3 flex flex-wrap gap-2">
                <span :for={member <- group.members} class="badge badge-outline gap-1">
                  {member.display_name || member.username}
                  <button
                    phx-click="remove_member"
                    phx-value-group={group.id}
                    phx-value-user={member.id}
                    class="ml-1 opacity-60 hover:opacity-100"
                    aria-label="remove from group"
                  >
                    x
                  </button>
                </span>
                <span :if={group.members == []} class="text-sm opacity-60">No members yet.</span>
              </div>

              <details class="collapse collapse-arrow mt-3 rounded-lg border border-base-300 bg-base-200">
                <summary class="collapse-title min-h-0 px-3 py-2 text-sm font-medium">
                  Personal info & notes
                </summary>
                <div class="collapse-content px-3 pb-3">
                  <form phx-submit="save_group_note">
                    <input type="hidden" name="group_id" value={group.id} />
                    <label class="text-xs font-semibold uppercase tracking-wide opacity-60">
                      Personal notes
                    </label>
                    <textarea
                      name="body"
                      rows="3"
                      maxlength="4000"
                      class="textarea textarea-bordered mt-1 w-full resize-y text-sm"
                      placeholder="Private notes about this group"
                    >{Map.get(@group_notes, group.id, "")}</textarea>
                    <div class="mt-2 flex justify-end">
                      <button type="submit" class="btn btn-sm">Save note</button>
                    </div>
                  </form>
                </div>
              </details>

              <form
                :if={addable_friends(@friends, group) != []}
                phx-submit="add_member"
                class="mt-3 flex gap-2"
              >
                <input type="hidden" name="group" value={group.id} />
                <select name="user" class="select select-sm flex-1">
                  <option :for={friend <- addable_friends(@friends, group)} value={friend.id}>
                    {friend.display_name || friend.username} (@{friend.username})
                  </option>
                </select>
                <button type="submit" class="btn btn-sm">Add</button>
              </form>
            </section>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(add_username: "", page_title: "Contacts") |> refresh()}
  end

  @impl true
  def handle_info({:veejr_notification, _notification}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("add_friend", %{"username" => input}, socket) do
    case Social.Address.parse(input) do
      {:local, username} ->
        {:noreply, socket |> add_local_friend(username) |> assign(add_username: "") |> refresh()}

      {:remote, username, authority} ->
        socket =
          case Social.send_remote_friend_request(
                 socket.assigns.current_scope.user,
                 username,
                 authority
               ) do
            {:ok, _} ->
              put_flash(socket, :info, "Request sent to @#{username}@#{authority}.")

            {:error, :already_friends} ->
              put_flash(socket, :error, "You are already friends with @#{username}@#{authority}.")

            {:error, :already_requested} ->
              put_flash(
                socket,
                :error,
                "A request with @#{username}@#{authority} is already pending."
              )

            {:error, {:http, 404}} ->
              put_flash(socket, :error, "#{authority} doesn't know any @#{username}.")

            {:error, _} ->
              put_flash(
                socket,
                :error,
                "Could not reach #{authority} - check the address, or try again later."
              )
          end

        {:noreply, socket |> assign(add_username: "") |> refresh()}

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

  def handle_event("request_notification", %{"id" => id}, socket) do
    case Messaging.accept_notification(socket.assigns.current_scope.user, id) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :origin_unreachable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sender's instance is unreachable right now - try again later."
         )}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Notification not found.") |> refresh()}
    end
  end

  def handle_event("decline_notification", %{"id" => id}, socket) do
    Messaging.decline_notification(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Social.remove_friend(socket.assigns.current_scope.user, String.to_integer(id))
    {:noreply, socket |> put_flash(:info, "Friend removed.") |> refresh()}
  end

  def handle_event("confirm_key", %{"id" => id}, socket) do
    case Social.confirm_new_key(socket.assigns.current_scope.user, String.to_integer(id)) do
      {:ok, friend} ->
        {:noreply,
         socket |> put_flash(:info, "New key accepted for @#{friend.username}.") |> refresh()}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, "Nothing to confirm for that friend.") |> refresh()}
    end
  end

  def handle_event("save_note", %{"contact_id" => contact_id, "body" => body}, socket) do
    case Social.upsert_contact_note(socket.assigns.current_scope.user, contact_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Contact note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_from(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that note.")}
    end
  end

  def handle_event("save_group_note", %{"group_id" => group_id, "body" => body}, socket) do
    case Social.upsert_group_note(socket.assigns.current_scope.user, group_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Group note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_from(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that group note.")}
    end
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    socket =
      case Social.create_group(socket.assigns.current_scope.user, %{name: String.trim(name)}) do
        {:ok, group} -> put_flash(socket, :info, "Group \"#{group.name}\" created.")
        {:error, changeset} -> put_flash(socket, :error, error_from(changeset))
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    Social.delete_group(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("add_member", %{"group" => group_id, "user" => user_id}, socket) do
    case Social.add_group_member(
           socket.assigns.current_scope.user,
           group_id,
           String.to_integer(user_id)
         ) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :not_a_friend} ->
        {:noreply, put_flash(socket, :error, "Only friends can join your groups.")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not add member.") |> refresh()}
    end
  end

  def handle_event("remove_member", %{"group" => group_id, "user" => user_id}, socket) do
    Social.remove_group_member(
      socket.assigns.current_scope.user,
      group_id,
      String.to_integer(user_id)
    )

    {:noreply, refresh(socket)}
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
    pending = Messaging.list_pending_notifications(user)
    friends = Social.list_friends(user)
    groups = Social.list_groups(user)

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: friends,
      groups: groups,
      contact_notes: Social.list_contact_notes(user),
      group_notes: Social.list_group_notes(user),
      key_changes:
        Enum.filter(friends, &(&1.pending_public_key && &1.pending_public_key != &1.public_key)),
      incoming: Social.list_incoming_requests(user),
      outgoing: Social.list_outgoing_requests(user),
      conversations: build_conversations(user, friends)
    )
  end

  defp addable_friends(friends, group) do
    member_ids = MapSet.new(group.members, & &1.id)
    Enum.reject(friends, &MapSet.member?(member_ids, &1.id))
  end

  defp build_conversations(user, friends) do
    handle_to_id = Map.new(friends, &{Social.Address.handle(&1), &1.id})

    user
    |> Messaging.list_history(kind: "message", limit: @conversation_limit)
    |> Enum.group_by(&participants(user, &1))
    |> Enum.map(fn {participants, envelopes} ->
      envelopes = Enum.sort_by(envelopes, & &1.id)

      %{
        key: conversation_key(participants),
        participants: participants,
        envelopes: envelopes,
        latest: List.last(envelopes),
        reply_ids:
          participants
          |> Enum.map(&handle_to_id[&1])
          |> Enum.reject(&is_nil/1)
          |> Enum.join(",")
      }
    end)
    |> Enum.sort_by(& &1.latest.id, :desc)
  end

  defp conversation_key(participants) do
    :crypto.hash(:md5, Enum.join(participants, "|"))
    |> Base.url_encode64(padding: false)
  end

  defp participants(user, envelope) do
    if envelope.sender_id == user.id do
      case Messaging.batch_recipients(user, envelope.batch_id) do
        [] -> ["notes to yourself"]
        handles -> Enum.sort(handles)
      end
    else
      [Social.Address.handle(envelope.sender)]
    end
  end

  defp error_from(%Ecto.Changeset{errors: [{_field, {msg, _}} | _]}), do: msg
  defp error_from(_), do: "Something went wrong."
end
