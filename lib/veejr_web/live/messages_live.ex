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
      <div class="overflow-hidden rounded-[32px] border border-slate-200 bg-slate-50 shadow-sm">
        <div class="flex flex-col gap-3 border-b border-slate-200 bg-white px-4 py-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight text-slate-950">Messages</h1>
            <p class="text-sm text-slate-500">End-to-end encrypted conversations</p>
          </div>
          <div class="flex items-center gap-2">
            <div class="hidden min-w-64 items-center rounded-full bg-slate-100 px-4 py-2 text-sm text-slate-500 sm:flex">
              Search messages
            </div>
            <button
              id="compose-new"
              phx-click="new_message"
              class={[
                "rounded-full px-4 py-2 text-sm font-medium transition",
                is_nil(@selected_conversation) &&
                  "bg-blue-600 text-white shadow-sm hover:bg-blue-700",
                @selected_conversation &&
                  "bg-slate-100 text-slate-700 hover:bg-slate-200"
              ]}
            >
              New chat
            </button>
          </div>
        </div>

        <section :if={@pending != []} class="border-b border-blue-100 bg-blue-50 px-4 py-3">
          <div class="mb-2 flex items-center justify-between">
            <h2 class="text-sm font-semibold text-blue-950">
              Waiting for you
              <span class="ml-1 rounded-full bg-blue-600 px-2 py-0.5 text-xs text-white">
                {length(@pending)}
              </span>
            </h2>
            <p class="hidden text-xs text-blue-700 sm:block">
              Nothing is downloaded until you request it.
            </p>
          </div>
          <ul class="grid gap-2 lg:grid-cols-2">
            <li
              :for={notif <- @pending}
              class="flex items-center justify-between gap-3 rounded-2xl border border-blue-100 bg-white px-3 py-2"
            >
              <span class="min-w-0 text-sm text-slate-700">
                <span class="font-medium text-slate-950">
                  {Veejr.Social.Address.handle(notif.envelope.sender)}
                </span>
                sent an encrypted {notif.envelope.kind}
                <span class="text-xs text-slate-500">
                  · {Calendar.strftime(notif.inserted_at, "%b %d, %H:%M")} UTC
                </span>
              </span>
              <span class="flex shrink-0 gap-2">
                <button
                  phx-click="request"
                  phx-value-id={notif.id}
                  class="rounded-full bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
                >
                  Request
                </button>
                <button
                  phx-click="decline"
                  phx-value-id={notif.id}
                  class="rounded-full px-3 py-1.5 text-xs font-medium text-slate-500 hover:bg-slate-100"
                >
                  Decline
                </button>
              </span>
            </li>
          </ul>
        </section>

        <section class="grid min-h-[42rem] overflow-hidden lg:h-[calc(100svh-12rem)] lg:min-h-0 lg:grid-cols-[22rem_minmax(0,1fr)]">
          <aside class="border-b border-slate-200 bg-white p-3 lg:overflow-y-auto lg:border-b-0 lg:border-r">
            <div class="mb-3 flex items-center justify-between px-2">
              <h2 class="text-sm font-semibold uppercase tracking-wide text-slate-500">
                Conversations
              </h2>
              <button
                id="compose-new-rail"
                phx-click="new_message"
                class="rounded-full px-3 py-1.5 text-xs font-medium text-blue-700 hover:bg-blue-50"
              >
                New
              </button>
            </div>
            <p :if={@conversations == []} class="px-2 py-6 text-sm text-slate-500">
              No conversations yet.
            </p>
            <div class="space-y-1">
              <button
                :for={conv <- @conversations}
                id={"conversation-#{conv.key}"}
                type="button"
                phx-click="select_conversation"
                phx-value-key={conv.key}
                class={[
                  "flex w-full items-center gap-3 rounded-[22px] px-3 py-3 text-left transition",
                  @selected_conversation_key == conv.key &&
                    "bg-blue-50 text-blue-950",
                  @selected_conversation_key != conv.key &&
                    "text-slate-800 hover:bg-slate-100"
                ]}
              >
                <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-blue-100 text-sm font-semibold text-blue-700">
                  {conversation_initials(conv)}
                </span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium">
                    {Enum.join(conv.participants, ", ")}
                  </span>
                  <span class="mt-0.5 flex items-center justify-between gap-2 text-xs text-slate-500">
                    <span>{length(conv.envelopes)} messages</span>
                    <span>{Calendar.strftime(conv.latest.inserted_at, "%b %d")}</span>
                  </span>
                </span>
              </button>
            </div>
          </aside>

          <main class="flex min-h-0 min-w-0 flex-col bg-slate-100/80">
            <div
              :if={@selected_conversation}
              class="flex min-h-0 flex-1 flex-col"
            >
              <div class="flex items-center justify-between gap-3 border-b border-slate-200 bg-white px-5 py-4">
                <div class="min-w-0">
                  <h2 class="truncate text-lg font-semibold text-slate-950">
                    {Enum.join(@selected_conversation.participants, ", ")}
                  </h2>
                  <p class="text-xs text-slate-500">
                    {length(@selected_conversation.envelopes)} messages
                  </p>
                </div>
                <button
                  id="new-message"
                  phx-click="new_message"
                  class="rounded-full px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100"
                >
                  New chat
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
                    type="button"
                    data-role="load-more-messages"
                    class="rounded-full bg-white px-3 py-1.5 text-xs font-medium text-slate-500 shadow-sm ring-1 ring-slate-200 hover:bg-slate-50"
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
                />
              </div>

              <section class="border-t border-slate-200 bg-white/90 p-3 backdrop-blur">
                <.composer
                  id="message-composer"
                  user={@current_scope.user}
                  friends={@friends}
                  groups={@groups}
                  kind="message"
                  surface="messages"
                  selected_friend_ids={selected_friend_ids(@selected_conversation)}
                  submit_label={composer_submit_label(@selected_conversation)}
                />
              </section>
            </div>

            <div
              :if={!@selected_conversation}
              class="flex flex-1 flex-col justify-end"
            >
              <div class="mx-auto max-w-xl px-6 py-12 text-center">
                <div class="mx-auto mb-4 flex size-14 items-center justify-center rounded-full bg-blue-100 text-xl font-semibold text-blue-700">
                  V
                </div>
                <h2 class="text-xl font-semibold text-slate-950">New conversation</h2>
                <p class="mt-2 text-sm text-slate-500">
                  Pick friends or groups, write a message, and send it encrypted.
                </p>
              </div>
              <section class="border-t border-slate-200 bg-white/90 p-3 backdrop-blur">
                <.composer
                  id="message-composer"
                  user={@current_scope.user}
                  friends={@friends}
                  groups={@groups}
                  kind="message"
                  surface="messages"
                  selected_friend_ids={[]}
                  submit_label="Send"
                />
              </section>
            </div>
          </main>
        </section>
      </div>
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
       message_limit: @message_page_size
     )
     |> refresh()}
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
    {:noreply, socket |> assign(:selected_conversation_key, key) |> refresh()}
  end

  def handle_event("new_message", _params, socket) do
    {:noreply, socket |> assign(:selected_conversation_key, nil) |> refresh()}
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

  def handle_event("resolve_recipients", params, socket) do
    {:reply, VeejrWeb.RecipientResolver.resolve(socket.assigns.current_scope.user, params),
     socket}
  end

  def handle_event("send_batch", %{"kind" => kind, "envelopes" => envelopes}, socket) do
    case Messaging.send_batch(socket.assigns.current_scope.user, kind, envelopes) do
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
    message_limit = socket.assigns[:message_limit] || @message_page_size
    {conversations, has_more_messages} = build_conversations(user, friends, message_limit)
    selected_key = socket.assigns[:selected_conversation_key]
    selected_conversation = Enum.find(conversations, &(&1.key == selected_key))
    selected_key = if selected_conversation, do: selected_key

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: friends,
      groups: Social.list_groups(user),
      conversations: conversations,
      has_more_messages: has_more_messages,
      selected_conversation: selected_conversation,
      selected_conversation_key: selected_key
    )
  end

  defp selected_friend_ids(%{reply_ids: reply_ids}) do
    reply_ids
    |> String.split(",", trim: true)
  end

  defp composer_submit_label(_conversation), do: "Send"

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

  # Groups history by participant set: what you sent to {@alice, @bob} and
  # what @alice sent you form separate threads (a received group message
  # lands in the sender's thread — the server can't see its other
  # recipients; the decrypted payload shows them).
  defp build_conversations(user, friends, limit) do
    handle_to_id = Map.new(friends, &{Veejr.Social.Address.handle(&1), &1.id})

    envelopes =
      user
      |> Messaging.list_history(kind: "message", limit: limit + 1)

    has_more? = length(envelopes) > limit

    conversations =
      envelopes
      |> Enum.take(limit)
      |> Enum.group_by(&participants(user, &1))
      |> Enum.map(fn {participants, envelopes} ->
        envelopes = Enum.sort_by(envelopes, & &1.id)

        %{
          key:
            :crypto.hash(:md5, Enum.join(participants, "|"))
            |> Base.url_encode64(padding: false),
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

    {conversations, has_more?}
  end

  defp participants(user, envelope) do
    if envelope.sender_id == user.id do
      case Messaging.batch_recipients(user, envelope.batch_id) do
        [] -> ["notes to yourself"]
        handles -> Enum.sort(handles)
      end
    else
      [Veejr.Social.Address.handle(envelope.sender)]
    end
  end
end
