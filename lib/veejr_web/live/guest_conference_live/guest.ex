defmodule VeejrWeb.GuestConferenceLive.Guest do
  use VeejrWeb, :live_view

  alias Veejr.{Accounts, GuestConferences}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      container_class="mx-auto max-w-xl space-y-6"
    >
      <div :if={@conference} id="guest-conference">
        <%= cond do %>
          <% @conference.state in ["sent", "waiting"] -> %>
            <section class="overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-xl">
              <div class="bg-primary/5 px-6 py-7 text-center">
                <span class="mx-auto flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
                  <.icon name="hero-video-camera" class="size-7" />
                </span>
                <p class="mt-4 text-xs font-semibold uppercase tracking-[0.18em] text-primary">
                  Private guest call
                </p>
                <h1 class="mt-2 text-2xl font-semibold tracking-tight">
                  {@conference.host.display_name || "@#{@conference.host.username}"} invited you
                </h1>
                <p class="mt-2 text-sm leading-relaxed opacity-65">
                  No account is required. Your host must admit you before the call connects.
                </p>
              </div>

              <div
                :if={@conference.state == "sent"}
                id="guest-device-lobby"
                phx-hook="GuestConferenceLobby"
                phx-update="ignore"
                data-guest-id={"guest-#{@conference.id}"}
                class="space-y-5 p-6"
              >
                <div>
                  <label for="guest-display-name" class="mb-1.5 block text-sm font-medium">
                    Your name
                  </label>
                  <input
                    id="guest-display-name"
                    type="text"
                    maxlength="80"
                    autocomplete="name"
                    placeholder="How the host will recognize you"
                    class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-3 outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                  />
                </div>

                <div class="relative aspect-video overflow-hidden rounded-2xl bg-black">
                  <video
                    data-role="guest-preview"
                    autoplay
                    playsinline
                    muted
                    class="size-full object-cover"
                  ></video>
                  <div
                    data-role="guest-preview-empty"
                    class="absolute inset-0 flex items-center justify-center p-5 text-center text-sm text-white/60"
                  >
                    Your private camera preview will appear here.
                  </div>
                </div>

                <p data-role="guest-lobby-status" role="alert" class="text-sm opacity-70"></p>

                <button
                  id="guest-ready"
                  type="button"
                  data-role="guest-ready"
                  class="btn btn-primary w-full rounded-xl"
                >
                  Check devices and enter waiting room
                </button>

                <p class="text-center text-xs leading-relaxed opacity-55">
                  Your temporary encryption identity stays in this browser tab and is discarded
                  after the conference.
                </p>
              </div>

              <div
                :if={@conference.state == "waiting"}
                id="guest-waiting"
                class="p-8 text-center"
              >
                <span class="loading loading-ring loading-lg text-primary"></span>
                <h2 class="mt-4 text-xl font-semibold">Waiting for your host</h2>
                <p class="mt-2 text-sm opacity-65">
                  Your devices are ready. This page will open the call when you are admitted.
                </p>
              </div>
            </section>
          <% @conference.state == "admitted" -> %>
            <section class="rounded-3xl border border-base-300 bg-base-100 p-8 text-center shadow-xl">
              <span class="loading loading-ring loading-lg text-primary"></span>
              <h1 class="mt-4 text-xl font-semibold">Opening your private call</h1>
            </section>
          <% @conference.state == "ended" -> %>
            <section
              id="guest-conference-complete"
              class="rounded-3xl border border-base-300 bg-base-100 p-7 text-center shadow-xl"
            >
              <span class="mx-auto flex size-14 items-center justify-center rounded-2xl bg-success/10 text-success">
                <.icon name="hero-check" class="size-7" />
              </span>
              <h1 class="mt-4 text-2xl font-semibold">Conference ended</h1>
              <p class="mt-2 text-sm leading-relaxed opacity-65">
                Guest chat, shared files, and your temporary conference identity are no longer
                available.
              </p>

              <div :if={is_nil(@conference.joined_at)} class="mt-7 rounded-2xl bg-primary/5 p-5">
                <h2 class="font-semibold">Stay connected</h2>
                <p class="mt-1 text-sm opacity-65">
                  Joining veejr is optional. If you continue, you and {@conference.host.display_name ||
                    "@#{@conference.host.username}"} will be
                  connected automatically.
                </p>
                <button
                  id="join-veejr-after-call"
                  phx-click="join_veejr"
                  class="btn btn-primary mt-4 w-full rounded-xl"
                >
                  Join veejr
                </button>
              </div>
              <p :if={@conference.joined_at} class="mt-5 text-sm opacity-65">
                Your membership invitation has already been created.
              </p>
            </section>
        <% end %>
      </div>

      <section
        :if={is_nil(@conference)}
        id="guest-conference-unavailable"
        class="rounded-3xl border border-base-300 bg-base-100 p-8 text-center"
      >
        <.icon name="hero-link-slash" class="mx-auto size-10 opacity-40" />
        <h1 class="mt-4 text-xl font-semibold">Invitation unavailable</h1>
        <p class="mt-2 text-sm opacity-65">
          This invitation has expired, was cancelled, or has already been declined.
        </p>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    conference = GuestConferences.get_by_token(token)

    if connected?(socket) and conference, do: GuestConferences.subscribe(conference)

    socket =
      assign(socket,
        page_title: "Guest video call",
        token: token,
        conference: conference
      )

    if conference && conference.state == "admitted" && conference.call do
      {:ok, push_navigate(socket, to: ~p"/guest/#{token}/call")}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event(
        "guest_ready",
        %{"display_name" => display_name, "public_key" => public_key},
        socket
      ) do
    case GuestConferences.put_waiting(socket.assigns.conference, %{
           display_name: display_name,
           public_key: public_key
         }) do
      {:ok, conference} ->
        {:reply, %{ok: true}, assign(socket, :conference, conference)}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          changeset.errors
          |> List.first()
          |> case do
            {_field, {text, _opts}} -> text
            _ -> "Please check your name and try again."
          end

        {:reply, %{ok: false, error: message}, socket}

      {:error, _reason} ->
        {:reply, %{ok: false, error: "This invitation is no longer available."}, socket}
    end
  end

  def handle_event("join_veejr", _params, socket) do
    conference = socket.assigns.conference

    if conference.state == "ended" and is_nil(conference.joined_at) do
      case Accounts.create_invitation(conference.host) do
        {:ok, _invitation, invite_token} ->
          {:ok, conference} = GuestConferences.mark_joined(conference)

          {:noreply,
           socket
           |> assign(:conference, conference)
           |> push_navigate(
             to: ~p"/users/register?#{%{invite: invite_token, email: conference.invited_email}}"
           )}

        {:error, :invitations_closed} ->
          {:noreply, put_flash(socket, :error, "Membership invitations are currently closed.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guest_conference_admitted, _call_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/guest/#{socket.assigns.token}/call")}
  end

  def handle_info({:guest_conference_closed, _state}, socket) do
    {:noreply, assign(socket, :conference, nil)}
  end

  def handle_info({:guest_conference_ended, conference}, socket) do
    {:noreply, assign(socket, :conference, conference)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
