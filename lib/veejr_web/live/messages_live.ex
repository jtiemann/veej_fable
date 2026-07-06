defmodule VeejrWeb.MessagesLive do
  use VeejrWeb, :live_view

  import VeejrWeb.MessagingComponents

  alias Veejr.{Messaging, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <.header>
        Messages
        <:subtitle>End-to-end encrypted. The server stores only ciphertext.</:subtitle>
      </.header>

      <section :if={@pending != []} class="mt-6">
        <h2 class="text-lg font-semibold">
          Waiting for you <span class="badge badge-primary">{length(@pending)}</span>
        </h2>
        <p class="text-sm opacity-60">
          Nothing is downloaded until you request it.
        </p>
        <ul class="mt-2 space-y-2">
          <li
            :for={notif <- @pending}
            class="flex items-center justify-between rounded-lg border border-primary/40 p-3"
          >
            <span>
              {kind_icon(notif.envelope.kind)}
              <span class="font-medium">
                {Veejr.Social.Address.handle(notif.envelope.sender)}
              </span>
              sent you an encrypted {notif.envelope.kind}
              <span class="opacity-60 text-sm">
                · {Calendar.strftime(notif.inserted_at, "%b %d, %H:%M")} UTC
              </span>
            </span>
            <span class="flex gap-2">
              <button phx-click="request" phx-value-id={notif.id} class="btn btn-primary btn-sm">
                Request it
              </button>
              <button phx-click="decline" phx-value-id={notif.id} class="btn btn-ghost btn-sm">
                Decline
              </button>
            </span>
          </li>
        </ul>
      </section>

      <section class="mt-8 grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
        <main class="min-w-0">
          <div
            :if={@selected_conversation}
            class="overflow-hidden rounded-2xl border border-base-300 bg-base-100"
          >
            <div class="flex items-center justify-between gap-3 border-b border-base-300 p-3">
              <div class="min-w-0">
                <h2 class="truncate text-lg font-semibold">
                  {Enum.join(@selected_conversation.participants, ", ")}
                </h2>
                <p class="text-xs opacity-60">
                  {length(@selected_conversation.envelopes)} messages
                </p>
              </div>
              <button
                id="new-message"
                phx-click="new_message"
                class="btn btn-ghost btn-sm shrink-0"
              >
                New message
              </button>
            </div>
            <div
              id={"thread-#{@selected_conversation.key}"}
              phx-hook="ScrollBottom"
              class="max-h-[32rem] overflow-y-auto px-3 py-2 bg-base-200/40"
            >
              <.message_bubble
                :for={envelope <- @selected_conversation.envelopes}
                envelope={envelope}
                user={@current_scope.user}
                mine={envelope.sender_id == @current_scope.user.id}
              />
            </div>
          </div>

          <div
            :if={!@selected_conversation && @conversations != []}
            class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">New message</h2>
            <p class="mt-1 text-sm opacity-60">
              Pick friends or groups below, or choose a previous conversation.
            </p>
          </div>

          <div
            :if={!@selected_conversation && @conversations == []}
            class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">New message</h2>
            <p class="mt-1 text-sm opacity-60">
              Messages you send and accept will appear as conversations.
            </p>
          </div>

          <section class="mt-4">
            <.composer
              id="message-composer"
              user={@current_scope.user}
              friends={@friends}
              groups={@groups}
              kind="message"
              selected_friend_ids={selected_friend_ids(@selected_conversation)}
              submit_label={composer_submit_label(@selected_conversation)}
            />
          </section>
        </main>

        <aside class="rounded-2xl border border-base-300 bg-base-100 p-3">
          <div class="flex items-center justify-between gap-2">
            <h2 class="text-lg font-semibold">Previous</h2>
            <button
              id="compose-new"
              phx-click="new_message"
              class={[
                "btn btn-ghost btn-sm",
                is_nil(@selected_conversation) && "btn-active"
              ]}
            >
              New
            </button>
          </div>
          <p :if={@conversations == []} class="mt-2 text-sm opacity-60">
            Nothing yet.
          </p>
          <div class="mt-3 space-y-2">
            <button
              :for={conv <- @conversations}
              id={"conversation-#{conv.key}"}
              type="button"
              phx-click="select_conversation"
              phx-value-key={conv.key}
              class={[
                "block w-full rounded-lg border p-3 text-left transition hover:border-primary/50 hover:bg-base-200",
                @selected_conversation_key == conv.key &&
                  "border-primary/60 bg-primary/10",
                @selected_conversation_key != conv.key &&
                  "border-base-300 bg-base-100"
              ]}
            >
              <span class="block truncate font-medium">
                {Enum.join(conv.participants, ", ")}
              </span>
              <span class="mt-1 flex items-center justify-between gap-2 text-xs opacity-60">
                <span class="badge badge-ghost badge-sm">{length(conv.envelopes)}</span>
                <span>{Calendar.strftime(conv.latest.inserted_at, "%b %d, %H:%M")}</span>
              </span>
            </button>
          </div>
        </aside>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Messages", selected_conversation_key: nil) |> refresh()}
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
    conversations = build_conversations(user, friends)
    selected_key = socket.assigns[:selected_conversation_key]
    selected_conversation = Enum.find(conversations, &(&1.key == selected_key))
    selected_key = if selected_conversation, do: selected_key

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: friends,
      groups: Social.list_groups(user),
      conversations: conversations,
      selected_conversation: selected_conversation,
      selected_conversation_key: selected_key
    )
  end

  defp selected_friend_ids(nil), do: []

  defp selected_friend_ids(%{reply_ids: reply_ids}) do
    reply_ids
    |> String.split(",", trim: true)
  end

  defp composer_submit_label(nil), do: "Encrypt & send"
  defp composer_submit_label(_conversation), do: "Encrypt & reply"

  # Groups history by participant set: what you sent to {@alice, @bob} and
  # what @alice sent you form separate threads (a received group message
  # lands in the sender's thread — the server can't see its other
  # recipients; the decrypted payload shows them).
  defp build_conversations(user, friends) do
    handle_to_id = Map.new(friends, &{Veejr.Social.Address.handle(&1), &1.id})

    user
    |> Messaging.list_history(kind: "message", limit: 200)
    |> Enum.group_by(&participants(user, &1))
    |> Enum.map(fn {participants, envelopes} ->
      envelopes = Enum.sort_by(envelopes, & &1.id)

      %{
        key:
          :crypto.hash(:md5, Enum.join(participants, "|")) |> Base.url_encode64(padding: false),
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
