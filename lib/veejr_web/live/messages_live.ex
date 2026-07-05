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
        <h2 class="text-lg font-semibold">Conversation history</h2>
        <p :if={@history == []} class="mt-2 text-sm opacity-60">
          Nothing yet. Messages you send and accept will appear here, decrypted
          only in your browser.
        </p>
        <ul class="mt-2 space-y-2">
          <.envelope_item
            :for={{envelope, label} <- @history}
            envelope={envelope}
            user={@current_scope.user}
            label={label}
          />
        </ul>
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

      {:ok, _batch_id, failures} ->
        {:reply, %{ok: true},
         socket
         |> put_flash(
           :error,
           "Sent, but #{Enum.join(failures, ", ")} could not be notified (instance unreachable). " <>
             "The encrypted copy is stored here — resend to them once their instance is back."
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

    history =
      user
      |> Messaging.list_history(kind: "message", limit: 100)
      |> Enum.map(&{&1, history_label(user, &1)})

    pending = Messaging.list_pending_notifications(user)

    assign(socket,
      pending: pending,
      pending_count: length(pending),
      friends: Social.list_friends(user),
      groups: Social.list_groups(user),
      history: history
    )
  end

  defp history_label(user, envelope) do
    if envelope.sender_id == user.id do
      case Messaging.batch_recipients(user, envelope.batch_id) do
        [] -> "To yourself"
        handles -> "To " <> Enum.join(handles, ", ")
      end
    else
      "From #{Veejr.Social.Address.handle(envelope.sender)}"
    end
  end
end
