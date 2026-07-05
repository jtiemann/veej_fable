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

      <section class="mt-6">
        <.composer
          id="message-composer"
          user={@current_scope.user}
          friends={@friends}
          groups={@groups}
          kind="message"
        />
      </section>

      <section class="mt-8">
        <h2 class="text-lg font-semibold">Conversations</h2>
        <p :if={@conversations == []} class="mt-2 text-sm opacity-60">
          Nothing yet. Messages you send and accept will appear here, decrypted
          only in your browser.
        </p>
        <div class="mt-2 space-y-3">
          <details
            :for={{conv, index} <- Enum.with_index(@conversations)}
            open={index == 0}
            class="rounded-lg border border-base-300"
          >
            <summary class="flex cursor-pointer items-center justify-between gap-2 p-3">
              <span class="font-medium truncate">💬 {Enum.join(conv.participants, ", ")}</span>
              <span class="flex items-center gap-2 whitespace-nowrap text-sm opacity-70">
                <span class="badge badge-ghost badge-sm">{length(conv.envelopes)}</span>
                {Calendar.strftime(conv.latest.inserted_at, "%b %d, %H:%M")}
              </span>
            </summary>
            <div class="border-t border-base-300 p-3">
              <ul class="space-y-2">
                <.envelope_item
                  :for={envelope <- conv.envelopes}
                  envelope={envelope}
                  user={@current_scope.user}
                  label={item_label(envelope, @current_scope.user)}
                />
              </ul>
              <button
                :if={conv.reply_ids != ""}
                id={"reply-#{conv.key}"}
                phx-hook="ReplyTo"
                data-friend-ids={conv.reply_ids}
                class="btn btn-ghost btn-sm mt-3"
              >
                ↩ Reply to this conversation
              </button>
            </div>
          </details>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Messages") |> refresh()}
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

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: friends,
      groups: Social.list_groups(user),
      conversations: build_conversations(user, friends)
    )
  end

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

  defp item_label(envelope, user) do
    if envelope.sender_id == user.id,
      do: "You",
      else: Veejr.Social.Address.handle(envelope.sender)
  end
end
