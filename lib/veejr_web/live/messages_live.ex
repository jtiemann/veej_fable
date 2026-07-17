defmodule VeejrWeb.MessagesLive do
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents

  alias Veejr.{Messaging, Social}

  @message_page_size 50

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-7xl"
    >
      <div class="overflow-hidden rounded-[32px] border border-base-300 bg-base-200 shadow-sm">
        <div class="border-b border-base-300 bg-base-100 px-4 py-4">
          <div>
            <.link
              id="back-to-contacts"
              navigate={~p"/contacts"}
              class="group mb-2 inline-flex items-center gap-1 text-sm font-medium text-base-content/65 transition hover:text-primary"
            >
              <.icon
                name="hero-arrow-left"
                class="size-4 transition-transform group-hover:-translate-x-0.5"
              /> Back to contacts
            </.link>
            <h1 class="text-2xl font-semibold tracking-tight text-base-content">Messages</h1>
            <p class="text-sm opacity-70">End-to-end encrypted conversations</p>
          </div>
        </div>

        <section :if={@pending != []} class="border-b border-primary/20 bg-primary/10 px-4 py-3">
          <div class="mb-2 flex items-center justify-between">
            <h2 class="text-sm font-semibold text-base-content">
              Waiting for you
              <span class="ml-1 rounded-full bg-primary px-2 py-0.5 text-xs text-primary-content">
                {length(@pending)}
              </span>
            </h2>
            <p class="hidden text-xs opacity-70 sm:block">
              Nothing is downloaded until you request it.
            </p>
          </div>
          <ul class="grid gap-2 lg:grid-cols-2">
            <li
              :for={notif <- @pending}
              class="flex items-center justify-between gap-3 rounded-2xl border border-primary/20 bg-base-100 px-3 py-2"
            >
              <span class="min-w-0 text-sm text-base-content">
                <span class="font-medium">
                  {Veejr.Social.Address.handle(notif.envelope.sender)}
                </span>
                sent an encrypted {notif.envelope.kind}
                <span class="text-xs opacity-70">
                  · {Calendar.strftime(notif.inserted_at, "%b %d, %H:%M")} UTC
                </span>
              </span>
              <span class="flex shrink-0 gap-2">
                <button
                  phx-click="request"
                  phx-value-id={notif.id}
                  class="rounded-full bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:bg-primary/90"
                >
                  Request
                </button>
                <button
                  phx-click="decline"
                  phx-value-id={notif.id}
                  class="rounded-full px-3 py-1.5 text-xs font-medium opacity-70 hover:bg-base-200 hover:opacity-100"
                >
                  Decline
                </button>
              </span>
            </li>
          </ul>
        </section>

        <section class="min-h-[42rem] overflow-hidden lg:h-[calc(100svh-12rem)] lg:min-h-0">
          <aside class="hidden border-b border-base-300 bg-base-100 p-3 lg:overflow-y-auto lg:border-b-0 lg:border-r">
            <div class="mb-3 flex items-center justify-between px-2">
              <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
                Conversations
              </h2>
              <button
                id="compose-new-rail"
                phx-click="new_message"
                class="rounded-full px-3 py-1.5 text-xs font-medium text-primary hover:bg-primary/10"
              >
                New
              </button>
            </div>
            <p :if={@conversations == []} class="px-2 py-6 text-sm opacity-70">
              No conversations yet.
            </p>
            <div class="space-y-1">
              <div
                :for={conv <- @conversations}
                class={[
                  "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
                  @selected_conversation_key == conv.key &&
                    "bg-primary/10 text-base-content",
                  @selected_conversation_key != conv.key &&
                    "text-base-content hover:bg-base-200"
                ]}
              >
                <.user_avatar
                  :if={conv.avatar_user}
                  id={"rail-conversation-avatar-#{conv.key}"}
                  user={conv.avatar_user}
                  class="size-10 text-sm"
                  on_click="open_profile"
                />
                <span
                  :if={!conv.avatar_user}
                  class="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/15 text-sm font-semibold text-primary"
                >
                  {conversation_initials(conv)}
                </span>
                <button
                  id={"conversation-#{conv.key}"}
                  type="button"
                  phx-click="select_conversation"
                  phx-value-key={conv.key}
                  class="min-w-0 flex-1 text-left"
                >
                  <span class="block truncate text-sm font-medium">
                    {conversation_title(conv)}
                  </span>
                  <span class="mt-0.5 flex items-center justify-between gap-2 text-xs opacity-70">
                    <span>{conv.message_count} messages</span>
                    <span>{Calendar.strftime(conv.latest.inserted_at, "%b %d")}</span>
                  </span>
                </button>
              </div>
            </div>

            <div
              :if={@available_friends != [] or @available_groups != []}
              class="mt-5 border-t border-base-300 pt-4"
            >
              <h2 class="mb-2 px-2 text-sm font-semibold uppercase tracking-wide opacity-70">
                Start new
              </h2>
              <div :if={@available_friends != []} class="space-y-1">
                <div
                  :for={friend <- @available_friends}
                  class={[
                    "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
                    @selected_recipient && @selected_recipient.type == :friend &&
                      @selected_recipient.id == friend.id && "bg-primary/10 text-base-content",
                    (!@selected_recipient || @selected_recipient.id != friend.id ||
                       @selected_recipient.type != :friend) &&
                      "text-base-content hover:bg-base-200"
                  ]}
                >
                  <.user_avatar
                    id={"message-friend-avatar-#{friend.id}"}
                    user={friend}
                    class="size-10 text-sm"
                    on_click="open_profile"
                  />
                  <button
                    id={"start-friend-#{friend.id}"}
                    type="button"
                    phx-click="select_friend"
                    phx-value-id={friend.id}
                    class="min-w-0 flex-1 text-left"
                  >
                    <span class="block truncate text-sm font-medium">
                      {friend.display_name || friend.username}
                    </span>
                    <span class="block truncate text-xs opacity-70">
                      {Social.Address.handle(friend)}
                    </span>
                  </button>
                </div>
              </div>

              <div :if={@available_groups != []} class="mt-3 space-y-1">
                <button
                  :for={group <- @available_groups}
                  id={"start-group-#{group.id}"}
                  type="button"
                  phx-click="select_group"
                  phx-value-id={group.id}
                  class={[
                    "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
                    @selected_recipient && @selected_recipient.type == :group &&
                      @selected_recipient.id == group.id && "bg-primary/10 text-base-content",
                    (!@selected_recipient || @selected_recipient.id != group.id ||
                       @selected_recipient.type != :group) &&
                      "text-base-content hover:bg-base-200"
                  ]}
                >
                  <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold opacity-80">
                    {group_initials(group)}
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-medium">{group.name}</span>
                    <span class="block truncate text-xs opacity-70">
                      {length(group.members)} members
                    </span>
                  </span>
                </button>
              </div>
            </div>
          </aside>

          <main class="flex h-full min-h-0 min-w-0 flex-col bg-base-200/80">
            <div
              :if={@selected_conversation}
              class="flex min-h-0 flex-1 flex-col"
            >
              <div class="flex items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-5 py-4">
                <div class="flex min-w-0 items-center gap-3">
                  <.user_avatar
                    :if={@selected_conversation.avatar_user}
                    user={@selected_conversation.avatar_user}
                    class="size-11 text-sm"
                    on_click="open_profile"
                  />
                  <span
                    :if={!@selected_conversation.avatar_user}
                    class="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
                  >
                    <.icon name="hero-user-group" class="size-5" />
                  </span>
                  <div class="min-w-0">
                    <h2 class="truncate text-lg font-semibold text-base-content">
                      {conversation_title(@selected_conversation)}
                    </h2>
                    <p class="text-xs opacity-70">
                      {@selected_conversation.message_count} messages
                    </p>
                  </div>
                </div>
                <button
                  id="archive-conversation"
                  phx-click="archive_conversation"
                  phx-value-key={@selected_conversation.key}
                  class="shrink-0 rounded-full px-3 py-1.5 text-sm font-medium opacity-80 hover:bg-base-200 hover:opacity-100"
                >
                  <.icon name="hero-archive-box" class="mr-1 inline size-4" /> Archive
                </button>
              </div>

              <div
                id={"thread-#{@selected_conversation.key}"}
                phx-hook="ScrollBottom"
                data-has-more={@has_more_messages}
                class="min-h-[26rem] flex-1 space-y-3 overflow-y-auto px-4 py-4 sm:px-6 lg:min-h-0"
              >
                <div class="py-2 text-center">
                  <button
                    :if={@has_more_messages}
                    id="load-more-messages"
                    type="button"
                    phx-click="load_more_messages"
                    data-role="load-more-messages"
                    class="rounded-full bg-base-100 px-3 py-1.5 text-xs font-medium opacity-70 shadow-sm ring-1 ring-base-300 hover:bg-base-200 hover:opacity-100"
                  >
                    Load earlier messages
                  </button>
                  <span :if={!@has_more_messages} class="text-xs opacity-50">
                    Beginning of loaded history
                  </span>
                </div>
                <.message_bubble
                  :for={envelope <- @selected_conversation.envelopes}
                  envelope={envelope}
                  user={@current_scope.user}
                  mine={envelope.sender_id == @current_scope.user.id}
                  profile_click="open_profile"
                />
                <div data-role="thread-end" aria-hidden="true" class="h-px shrink-0" />
              </div>

              <section class="sticky bottom-0 z-20 border-t border-base-300 bg-base-100/90 p-3 shadow-[0_-8px_24px_rgba(0,0,0,0.06)] backdrop-blur">
                <.composer
                  id="message-composer"
                  user={@current_scope.user}
                  friends={@friends}
                  groups={@groups}
                  kind="message"
                  surface="messages"
                  show_recipients={false}
                  selected_friend_ids={selected_friend_ids(@selected_conversation)}
                  selected_self={selected_self?(@selected_conversation)}
                  submit_label={composer_submit_label(@selected_conversation)}
                />
              </section>
            </div>

            <div
              :if={!@selected_conversation}
              class="flex flex-1 flex-col justify-end"
            >
              <div class="mx-auto max-w-xl px-6 py-12 text-center">
                <.user_avatar
                  :if={selected_recipient_user(@selected_recipient)}
                  id="selected-recipient-avatar"
                  user={selected_recipient_user(@selected_recipient)}
                  class="mx-auto mb-4 size-16 text-lg"
                  on_click="open_profile"
                />
                <div
                  :if={!selected_recipient_user(@selected_recipient)}
                  class="mx-auto mb-4 flex size-14 items-center justify-center rounded-full bg-primary/15 text-xl font-semibold text-primary"
                >
                  {selected_recipient_initials(@selected_recipient)}
                </div>
                <h2 class="text-xl font-semibold text-base-content">
                  {selected_recipient_title(@selected_recipient)}
                </h2>
                <p class="mt-2 text-sm opacity-70">
                  {selected_recipient_subtitle(@selected_recipient)}
                </p>
              </div>
              <section class="border-t border-base-300 bg-base-100/90 p-3 backdrop-blur">
                <.composer
                  id="message-composer"
                  user={@current_scope.user}
                  friends={@friends}
                  groups={@groups}
                  kind="message"
                  surface="messages"
                  show_recipients={false}
                  selected_self={selected_recipient_self?(@selected_recipient)}
                  selected_friend_ids={selected_recipient_friend_ids(@selected_recipient)}
                  selected_group_ids={selected_recipient_group_ids(@selected_recipient)}
                  submit_label="Send"
                />
              </section>
            </div>
          </main>
        </section>
      </div>

      <.profile_dialog
        user={@selected_profile}
        note={profile_note(@contact_notes, @selected_profile)}
        editable={profile_editable?(@friends, @selected_profile)}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Messages",
       selected_conversation_key: nil,
       selected_recipient_type: nil,
       selected_recipient_id: nil,
       selected_profile: nil,
       message_limit: @message_page_size
     )
     |> refresh()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     params
     |> apply_message_params(socket)
     |> reset_message_limit()
     |> refresh()
     |> scroll_to_selected()}
  end

  @impl true
  def handle_event("request", %{"id" => id}, socket) do
    case Messaging.accept_notification(socket.assigns.current_scope.user, id) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :origin_unreachable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The sender's instance is unreachable right now — try again later."
         )}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Notification not found.") |> refresh()}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    Messaging.decline_notification(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("select_conversation", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:selected_conversation_key, key)
     |> reset_message_limit()
     |> clear_selected_recipient()
     |> refresh()
     |> scroll_to_selected()}
  end

  def handle_event("archive_conversation", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.conversations, &(&1.key == key)) do
      %{
        participants: participants,
        envelope_ids: envelope_ids,
        started_at: started_at
      } ->
        case Messaging.archive_conversation(
               socket.assigns.current_scope.user,
               key,
               participants,
               envelope_ids,
               started_at
             ) do
          {:ok, _archive} ->
            {:noreply,
             socket
             |> assign(:selected_conversation_key, nil)
             |> reset_message_limit()
             |> clear_selected_recipient()
             |> put_flash(:info, "Conversation archived.")
             |> refresh()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not archive that conversation.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Conversation not found.")}
    end
  end

  def handle_event("new_message", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_conversation_key, nil)
     |> reset_message_limit()
     |> clear_selected_recipient()
     |> refresh()}
  end

  def handle_event("select_friend", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(
       selected_conversation_key: nil,
       selected_recipient_type: :friend,
       selected_recipient_id: id,
       message_limit: @message_page_size
     )
     |> refresh()}
  end

  def handle_event("select_group", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(
       selected_conversation_key: nil,
       selected_recipient_type: :group,
       selected_recipient_id: id,
       message_limit: @message_page_size
     )
     |> refresh()}
  end

  def handle_event("open_profile", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    profiles =
      [user | socket.assigns.friends] ++
        Enum.map(socket.assigns.pending, & &1.envelope.sender) ++
        Enum.flat_map(socket.assigns.conversations, fn conversation ->
          Enum.map(conversation.envelopes, & &1.sender)
        end)

    profile = Enum.find(profiles, &(to_string(&1.id) == id))

    {:noreply, assign(socket, :selected_profile, profile)}
  end

  def handle_event("close_profile", _params, socket) do
    {:noreply, assign(socket, :selected_profile, nil)}
  end

  def handle_event(
        "save_profile_note",
        %{"contact_id" => contact_id, "body" => body},
        socket
      ) do
    case Social.upsert_contact_note(socket.assigns.current_scope.user, contact_id, body) do
      {:ok, _note} ->
        {:noreply, socket |> put_flash(:info, "Contact note saved.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, profile_note_error(changeset))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save that note.")}
    end
  end

  def handle_event("load_more_messages", _params, socket) do
    limit = socket.assigns.message_limit + @message_page_size
    {:noreply, socket |> assign(:message_limit, limit) |> refresh()}
  end

  def handle_event("delete_envelope", %{"id" => public_id}, socket) do
    case Messaging.delete_envelope(socket.assigns.current_scope.user, public_id) do
      {:ok, {:deleted, _count}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted for every recipient.")
         |> refresh()}

      {:ok, :hidden} ->
        {:noreply,
         socket
         |> put_flash(:info, "Hidden from your history.")
         |> refresh()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not delete that item.")
         |> refresh()}
    end
  end

  def handle_event("message_displayed", %{"id" => public_id}, socket) do
    case Messaging.record_display(socket.assigns.current_scope.user, public_id) do
      {:ok, envelope}
      when is_integer(envelope.max_displays) and
             envelope.display_count >= envelope.max_displays ->
        {:reply, %{ok: true}, refresh(socket)}

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  def handle_event("prepare_edit", %{"id" => public_id}, socket) do
    case Messaging.editable_batch(socket.assigns.current_scope.user, public_id) do
      {:ok, batch} -> {:reply, Map.put(batch, :ok, true), socket}
      {:error, _} -> {:reply, %{error: "That message can no longer be edited."}, socket}
    end
  end

  def handle_event("edit_batch", %{"id" => public_id, "envelopes" => envelopes}, socket) do
    case Messaging.edit_sent_batch(socket.assigns.current_scope.user, public_id, envelopes) do
      {:ok, _count} ->
        {:reply, %{ok: true}, socket |> put_flash(:info, "Message updated.") |> refresh()}

      {:error, _} ->
        {:reply, %{error: "Could not update that message."}, socket}
    end
  end

  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  def handle_event("send_batch", %{"kind" => kind, "envelopes" => envelopes} = params, socket) do
    opts = Map.take(params, ["expires_at", "max_displays"])

    case Messaging.send_batch(socket.assigns.current_scope.user, kind, envelopes, opts) do
      {:ok, _batch_id, []} ->
        {:reply, %{ok: true}, socket |> put_flash(:info, "Encrypted and sent.") |> refresh()}

      {:ok, _batch_id, queued} ->
        {:reply, %{ok: true},
         socket
         |> put_flash(
           :info,
           "Encrypted and sent. #{Enum.join(queued, ", ")}: instance unreachable right now — " <>
             "the notification is queued and will be retried automatically."
         )
         |> refresh()}

      {:error, _} ->
        {:reply, %{error: "Sending failed — are all recipients still your friends?"}, socket}
    end
  end

  @impl true
  def handle_info({:veejr_notification, _notification}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    user = socket.assigns.current_scope.user
    pending = Messaging.list_pending_notifications(user)
    friends = Social.list_friends(user)
    groups = Social.list_groups(user)
    message_limit = socket.assigns[:message_limit] || @message_page_size
    selected_key = socket.assigns[:selected_conversation_key]

    {conversations, has_more_messages} =
      build_conversations(user, friends, message_limit, selected_key)

    selected_conversation = Enum.find(conversations, &(&1.key == selected_key))
    selected_key = if selected_conversation, do: selected_key
    selected_recipient = selected_recipient(socket, friends, groups)

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: friends,
      groups: groups,
      contact_notes: Social.list_contact_notes(user),
      available_friends: available_friends(friends, conversations),
      available_groups: available_groups(groups, conversations),
      conversations: conversations,
      has_more_messages: has_more_messages,
      selected_conversation: selected_conversation,
      selected_conversation_key: selected_key,
      selected_recipient: selected_recipient
    )
  end

  defp clear_selected_recipient(socket) do
    assign(socket, selected_recipient_type: nil, selected_recipient_id: nil)
  end

  defp reset_message_limit(socket), do: assign(socket, :message_limit, @message_page_size)

  defp scroll_to_selected(socket) do
    case socket.assigns[:selected_conversation_key] do
      key when is_binary(key) ->
        push_event(socket, "scroll_to_bottom", %{thread_id: "thread-#{key}"})

      _ ->
        socket
    end
  end

  defp apply_message_params(%{"conversation" => key}, socket) when is_binary(key) do
    socket
    |> assign(:selected_conversation_key, key)
    |> clear_selected_recipient()
  end

  defp apply_message_params(%{"friend_id" => id}, socket) do
    assign(socket,
      selected_conversation_key: nil,
      selected_recipient_type: :friend,
      selected_recipient_id: id
    )
  end

  defp apply_message_params(%{"group_id" => id}, socket) do
    assign(socket,
      selected_conversation_key: nil,
      selected_recipient_type: :group,
      selected_recipient_id: id
    )
  end

  defp apply_message_params(%{"friend_ids" => _ids} = params, socket) do
    assign_multi_recipient(socket, params)
  end

  defp apply_message_params(%{"group_ids" => _ids} = params, socket) do
    assign_multi_recipient(socket, params)
  end

  defp apply_message_params(_params, socket) do
    socket
    |> assign(:selected_conversation_key, nil)
    |> clear_selected_recipient()
  end

  defp selected_recipient(socket, friends, groups) do
    id = socket.assigns[:selected_recipient_id]

    case socket.assigns[:selected_recipient_type] do
      :friend ->
        with {friend_id, ""} <- Integer.parse(to_string(id)),
             friend when not is_nil(friend) <- Enum.find(friends, &(&1.id == friend_id)) do
          %{
            type: :friend,
            id: friend.id,
            title: friend.display_name || friend.username,
            subtitle: Social.Address.handle(friend),
            friend_ids: [to_string(friend.id)],
            group_ids: [],
            initials: person_initials(friend),
            user: friend
          }
        else
          _ -> nil
        end

      :group ->
        with {group_id, ""} <- Integer.parse(to_string(id)),
             group when not is_nil(group) <- Enum.find(groups, &(&1.id == group_id)) do
          %{
            type: :group,
            id: group.id,
            title: group.name,
            subtitle: "#{length(group.members)} members",
            friend_ids: [],
            group_ids: [to_string(group.id)],
            initials: group_initials(group)
          }
        else
          _ -> nil
        end

      :multi ->
        selected = id || %{}
        friend_ids = Map.get(selected, :friend_ids, [])
        group_ids = Map.get(selected, :group_ids, [])
        include_self = Map.get(selected, :include_self, false)
        friend_id_set = MapSet.new(friend_ids)
        group_id_set = MapSet.new(group_ids)
        chosen_friends = Enum.filter(friends, &MapSet.member?(friend_id_set, to_string(&1.id)))
        chosen_groups = Enum.filter(groups, &MapSet.member?(group_id_set, to_string(&1.id)))

        recipient_ids =
          chosen_friends
          |> Enum.map(&to_string(&1.id))
          |> Kernel.++(
            chosen_groups
            |> Enum.flat_map(& &1.members)
            |> Enum.map(&to_string(&1.id))
          )
          |> Enum.uniq()

        count = length(recipient_ids) + if(include_self, do: 1, else: 0)

        if count > 0 do
          %{
            type: :multi,
            id: "multi",
            title: "New conversation",
            subtitle: "#{count} selected #{if(count == 1, do: "recipient", else: "recipients")}",
            friend_ids: Enum.map(chosen_friends, &to_string(&1.id)),
            group_ids: Enum.map(chosen_groups, &to_string(&1.id)),
            include_self: include_self,
            initials: "NEW"
          }
        end

      _ ->
        nil
    end
  end

  defp selected_friend_ids(%{reply_ids: reply_ids}) do
    reply_ids
    |> String.split(",", trim: true)
  end

  defp selected_self?(%{participants: ["notes to yourself"]}), do: true
  defp selected_self?(_), do: false

  defp selected_recipient_self?(nil), do: true
  defp selected_recipient_self?(%{include_self: include_self}), do: include_self
  defp selected_recipient_self?(_), do: false

  defp selected_recipient_friend_ids(%{friend_ids: friend_ids}), do: friend_ids
  defp selected_recipient_friend_ids(_), do: []

  defp selected_recipient_group_ids(%{group_ids: group_ids}), do: group_ids
  defp selected_recipient_group_ids(_), do: []

  defp selected_recipient_title(%{title: title}), do: title
  defp selected_recipient_title(_), do: "Notes to yourself"

  defp selected_recipient_subtitle(%{subtitle: subtitle}), do: subtitle
  defp selected_recipient_subtitle(_), do: "Send an encrypted message to this account."

  defp selected_recipient_initials(%{initials: initials}), do: initials
  defp selected_recipient_initials(_), do: "ME"

  defp selected_recipient_user(%{user: user}), do: user
  defp selected_recipient_user(_), do: nil

  defp profile_note(_notes, nil), do: ""
  defp profile_note(notes, profile), do: Map.get(notes, profile.id, "")

  defp profile_editable?(_friends, nil), do: false
  defp profile_editable?(friends, profile), do: Enum.any?(friends, &(&1.id == profile.id))

  defp profile_note_error(%Ecto.Changeset{errors: [{_field, {message, _}} | _]}), do: message
  defp profile_note_error(_changeset), do: "Could not save that note."

  defp composer_submit_label(_conversation), do: "Send"

  defp assign_multi_recipient(socket, params) do
    friend_ids = parse_id_list(Map.get(params, "friend_ids"))
    group_ids = parse_id_list(Map.get(params, "group_ids"))
    include_self = Map.get(params, "include_self") in [true, "true", "1", "on"]

    assign(socket,
      selected_conversation_key: nil,
      selected_recipient_type: :multi,
      selected_recipient_id: %{
        friend_ids: friend_ids,
        group_ids: group_ids,
        include_self: include_self
      }
    )
  end

  defp parse_id_list(nil), do: []

  defp parse_id_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.uniq()
  end

  defp available_friends(friends, conversations) do
    used_ids =
      conversations
      |> Enum.flat_map(&selected_friend_ids/1)
      |> MapSet.new()

    Enum.reject(friends, &(to_string(&1.id) in used_ids))
  end

  defp available_groups(groups, conversations) do
    conversation_participants = MapSet.new(conversations, & &1.participants)

    Enum.reject(groups, fn group ->
      group
      |> group_participant_handles()
      |> then(&MapSet.member?(conversation_participants, &1))
    end)
  end

  defp person_initials(user) do
    user
    |> display_name()
    |> initials()
  end

  defp group_initials(group) do
    group.name
    |> initials()
  end

  defp display_name(user), do: user.display_name || user.username || Social.Address.handle(user)

  defp conversation_initials(%{participants: participants}) do
    participants
    |> Enum.take(2)
    |> Enum.map_join("", fn participant ->
      participant
      |> String.trim_leading("@")
      |> String.first()
      |> case do
        nil -> "?"
        initial -> String.upcase(initial)
      end
    end)
  end

  defp initials(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", fn word ->
      word
      |> String.trim_leading("@")
      |> String.first()
      |> case do
        nil -> "?"
        initial -> String.upcase(initial)
      end
    end)
    |> case do
      "" -> "?"
      result -> result
    end
  end

  defp group_participant_handles(group) do
    group.members
    |> Enum.map(&Social.Address.handle/1)
    |> Enum.sort()
  end

  # Groups history by participant set: what you sent to {@alice, @bob} and
  # what @alice sent you form separate threads (a received group message
  # lands in the sender's thread — the server can't see its other
  # recipients; the decrypted payload shows them).
  defp build_conversations(user, friends, limit, selected_key) do
    handle_to_friend = Map.new(friends, &{Veejr.Social.Address.handle(&1), &1})

    # Conversation keys are derived from participants, so history must be
    # grouped before applying the per-conversation display window. Limiting
    # this query first would let newer messages in another thread hide older
    # messages from the selected conversation.
    envelopes =
      user
      |> Messaging.list_history(kind: "message")

    conversations =
      envelopes
      |> then(&Messaging.conversation_threads(user, &1))
      |> Enum.map(fn thread ->
        envelopes = thread.envelopes
        participants = thread.participants
        message_count = length(envelopes)

        Map.merge(thread, %{
          envelopes: Enum.take(envelopes, -limit),
          message_count: message_count,
          reply_ids:
            participants
            |> Enum.map(&handle_to_friend[&1])
            |> Enum.reject(&is_nil/1)
            |> Enum.map(& &1.id)
            |> Enum.join(","),
          avatar_user:
            case participants do
              ["notes to yourself"] -> user
              [handle] -> handle_to_friend[handle]
              _ -> nil
            end
        })
      end)
      |> Enum.sort_by(& &1.latest.id, :desc)

    has_more? =
      case Enum.find(conversations, &(&1.key == selected_key)) do
        %{message_count: count} -> count > limit
        _ -> false
      end

    {conversations, has_more?}
  end

  defp conversation_title(conversation) do
    title = Enum.join(conversation.participants, ", ")

    if conversation.preserved do
      "#{title} · #{Calendar.strftime(conversation.started_at, "%b %d, %Y")}"
    else
      title
    end
  end
end
