defmodule VeejrWeb.WatchLive do
  @moduledoc "Instance-local, host-controlled YouTube watch parties."

  use VeejrWeb, :live_view

  alias Veejr.WatchParties

  @impl true
  def mount(params, _session, socket) do
    party = party_for_action(socket.assigns.live_action, params)

    if connected?(socket) and party, do: WatchParties.subscribe(party.public_id)

    socket =
      socket
      |> assign(:party, party)
      |> assign(:host?, party && party.host_id == socket.assigns.current_scope.user.id)
      |> assign(:watch_form, to_form(%{"url" => ""}, as: :watch))

    case {socket.assigns.live_action, party} do
      {:show, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "That watch party has ended.")
         |> push_navigate(to: ~p"/watch")}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("start", %{"watch" => %{"url" => url}}, socket) do
    case WatchParties.start_party(socket.assigns.current_scope.user, url) do
      {:ok, party} ->
        {:noreply, push_navigate(socket, to: ~p"/watch/#{party.public_id}")}

      {:error, :party_active} ->
        {:noreply, put_flash(socket, :error, "A watch party is already active.")}

      {:error, :invalid_youtube_url} ->
        {:noreply, put_flash(socket, :error, "Enter a valid YouTube link or video ID.")}
    end
  end

  def handle_event("watch_control", %{"playback" => playback, "position" => position}, socket) do
    if socket.assigns.host? do
      WatchParties.control(
        socket.assigns.party.public_id,
        socket.assigns.current_scope.user.id,
        playback,
        position
      )
    end

    {:noreply, socket}
  end

  def handle_event("end_party", _params, socket) do
    if socket.assigns.host? do
      WatchParties.end_party(socket.assigns.party.public_id, socket.assigns.current_scope.user.id)
    end

    {:noreply, push_navigate(socket, to: ~p"/watch")}
  end

  @impl true
  def handle_info({:watch_party_control, party}, socket) do
    socket = assign(socket, :party, party)

    if socket.assigns.host? do
      {:noreply, socket}
    else
      {:noreply,
       push_event(socket, "watch:control", %{
         playback: party.playback,
         position: party.position
       })}
    end
  end

  def handle_info({:watch_party_ended, _public_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "The host ended the watch party.")
     |> push_navigate(to: ~p"/watch")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-5xl"
    >
      <%= if @live_action == :show do %>
        <section id="watch-party" class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p class="text-sm font-medium text-primary">YouTube watch party</p>
              <h1 class="text-2xl font-semibold tracking-tight">Hosted by {@party.host}</h1>
              <p class="mt-1 text-sm opacity-65">
                <%= if @host? do %>
                  Your YouTube controls direct playback for everyone.
                <% else %>
                  Only the host can play, pause, or seek.
                <% end %>
              </p>
            </div>
            <button :if={@host?} id="watch-end" phx-click="end_party" class="btn btn-error btn-sm">
              <.icon name="hero-stop" class="size-4" /> End party
            </button>
          </div>

          <div class="overflow-hidden rounded-[28px] border border-base-300 bg-black shadow-xl">
            <div
              id="youtube-watch-player"
              phx-hook="YouTubeWatch"
              phx-update="ignore"
              data-host={to_string(@host?)}
              data-playback={@party.playback}
              data-position={@party.position}
              class="relative aspect-video w-full"
            >
              <iframe
                id="youtube-watch-iframe"
                data-role="player"
                src={youtube_embed_url(@party.video_id, @host?)}
                title="Shared YouTube video"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowfullscreen
                referrerpolicy="strict-origin-when-cross-origin"
                class={["absolute inset-0 size-full", !@host? && "pointer-events-none"]}
              ></iframe>
              <button
                :if={!@host?}
                type="button"
                data-role="unlock"
                class="absolute inset-0 flex size-full cursor-pointer items-center justify-center bg-black/35 text-white transition hover:bg-black/25"
              >
                <span class="rounded-full bg-black/75 px-5 py-3 text-sm font-semibold shadow-lg backdrop-blur">
                  <.icon name="hero-play" class="mr-1 inline size-5" /> Tap to join playback
                </span>
              </button>
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-base-300 bg-base-100 p-4">
            <p class="text-sm opacity-65">
              veejr relays synchronization directions only; video streams directly from YouTube.
            </p>
            <button
              id="watch-fullscreen"
              type="button"
              data-watch-fullscreen
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-pointing-out" class="size-4" /> Full screen
            </button>
          </div>
        </section>
      <% else %>
        <section id="watch-lobby" class="mx-auto max-w-2xl space-y-5">
          <div class="rounded-[30px] border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8">
            <div class="mb-6 flex size-12 items-center justify-center rounded-2xl bg-error/10 text-error">
              <.icon name="hero-play" class="size-7" />
            </div>
            <h1 class="text-3xl font-semibold tracking-tight">Watch YouTube together</h1>
            <p class="mt-2 leading-relaxed opacity-70">
              Start one shared video for everyone currently online on this veejr instance. People choose whether to join, and only you control playback.
            </p>

            <%= if @party do %>
              <div
                id="active-watch-party"
                class="mt-6 rounded-2xl border border-primary/25 bg-primary/5 p-5"
              >
                <p class="font-semibold">{@party.host} is hosting now</p>
                <p class="mt-1 text-sm opacity-65">
                  Join the synchronized video already in progress.
                </p>
                <.link navigate={~p"/watch/#{@party.public_id}"} class="btn btn-primary mt-4">
                  <.icon name="hero-play" class="size-4" />
                  {if @party.host_id == @current_scope.user.id,
                    do: "Resume hosting",
                    else: "Join party"}
                </.link>
              </div>
            <% else %>
              <.form for={@watch_form} id="watch-start-form" phx-submit="start" class="mt-6 space-y-4">
                <.input
                  field={@watch_form[:url]}
                  type="text"
                  label="YouTube link or video ID"
                  placeholder="https://www.youtube.com/watch?v=..."
                  autocomplete="off"
                  required
                />
                <button id="watch-start" type="submit" class="btn btn-primary w-full sm:w-auto">
                  <.icon name="hero-user-group" class="size-4" /> Start watch party
                </button>
              </.form>
            <% end %>
          </div>
        </section>
      <% end %>
    </Layouts.app>
    """
  end

  defp party_for_action(:new, _params), do: WatchParties.active_party()

  defp party_for_action(:show, %{"public_id" => public_id}) do
    case WatchParties.active_party() do
      %{public_id: ^public_id} = party -> party
      _ -> nil
    end
  end

  defp youtube_embed_url(video_id, host?) do
    query =
      URI.encode_query(%{
        "enablejsapi" => "1",
        "playsinline" => "1",
        "rel" => "0",
        "controls" => if(host?, do: "1", else: "0")
      })

    "https://www.youtube-nocookie.com/embed/#{video_id}?#{query}"
  end
end
