defmodule VeejrWeb.GuestConferenceLive.Host do
  use VeejrWeb, :live_view

  alias Veejr.{Calls, GuestConferences}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-6"
    >
      <.header>
        Guest waiting room
        <:subtitle>
          Only admit the person you expected. The conference stays private until you do.
        </:subtitle>
      </.header>

      <section
        id="guest-conference-host"
        class="overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-sm"
      >
        <div class="flex flex-col gap-5 p-6 sm:flex-row sm:items-center sm:justify-between">
          <div class="flex min-w-0 items-center gap-4">
            <span class={[
              "flex size-14 shrink-0 items-center justify-center rounded-2xl",
              if(@conference.state == "waiting",
                do: "bg-success/10 text-success",
                else: "bg-primary/10 text-primary"
              )
            ]}>
              <.icon
                name={if(@conference.state == "waiting", do: "hero-user", else: "hero-envelope")}
                class="size-7"
              />
            </span>
            <div class="min-w-0">
              <p id="guest-conference-status" class="font-semibold">
                {status_title(@conference)}
              </p>
              <p class="truncate text-sm opacity-65">{@conference.invited_email}</p>
              <p :if={@conference.display_name} class="mt-1 text-lg font-semibold">
                {@conference.display_name}
              </p>
            </div>
          </div>

          <div :if={@conference.state == "waiting"} class="flex shrink-0 gap-2">
            <button id="decline-guest" phx-click="decline" class="btn btn-ghost rounded-xl">
              Decline
            </button>
            <button id="admit-guest" phx-click="admit" class="btn btn-primary rounded-xl">
              <.icon name="hero-video-camera" class="size-4" /> Admit
            </button>
          </div>
        </div>

        <div
          :if={@conference.state == "sent"}
          class="border-t border-base-300 bg-base-200/60 px-6 py-4"
        >
          <div class="flex items-center gap-3 text-sm opacity-70">
            <span class="loading loading-dots loading-sm"></span>
            Waiting for the guest to open the email and check their devices.
          </div>
        </div>
      </section>

      <div class="flex items-center justify-between">
        <.link navigate={~p"/guest-conferences/new"} class="btn btn-ghost btn-sm">
          Invite someone else
        </.link>
        <button
          :if={@conference.state in ["sent", "waiting"]}
          id="cancel-guest-invitation"
          phx-click="revoke"
          class="btn btn-outline btn-sm"
        >
          Cancel invitation
        </button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    host = socket.assigns.current_scope.user

    case GuestConferences.get_for_host(host, public_id) do
      {:ok, conference} ->
        if connected?(socket), do: GuestConferences.subscribe(conference)

        {:ok,
         assign(socket,
           page_title: "Guest waiting room",
           conference: conference
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That guest conference does not exist.")
         |> push_navigate(to: ~p"/guest-conferences/new", replace: true)}
    end
  end

  @impl true
  def handle_event("admit", _params, socket) do
    host = socket.assigns.current_scope.user

    case Calls.start_guest_call(host, socket.assigns.conference) do
      {:ok, _call} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/guest-conferences/#{socket.assigns.conference.public_id}/call"
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The guest could not be admitted.")}
    end
  end

  def handle_event("decline", _params, socket) do
    {:ok, conference} =
      GuestConferences.decline(
        socket.assigns.current_scope.user,
        socket.assigns.conference
      )

    {:noreply, assign(socket, :conference, conference)}
  end

  def handle_event("revoke", _params, socket) do
    {:ok, conference} =
      GuestConferences.revoke(
        socket.assigns.current_scope.user,
        socket.assigns.conference
      )

    {:noreply,
     socket
     |> assign(:conference, conference)
     |> put_flash(:info, "The guest invitation was cancelled.")}
  end

  @impl true
  def handle_info({:guest_conference_waiting, conference}, socket) do
    {:noreply, assign(socket, :conference, conference)}
  end

  def handle_info({:guest_conference_ended, conference}, socket) do
    {:noreply, assign(socket, :conference, conference)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp status_title(%{state: "sent"}), do: "Invitation sent"
  defp status_title(%{state: "waiting"}), do: "Guest is ready to join"
  defp status_title(%{state: "admitted"}), do: "Guest admitted"
  defp status_title(%{state: "ended"}), do: "Conference ended"
  defp status_title(%{state: "declined"}), do: "Invitation declined"
  defp status_title(%{state: "revoked"}), do: "Invitation cancelled"
end
