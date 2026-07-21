defmodule VeejrWeb.CallLive do
  @moduledoc """
  One active 1:1 call. Both participants sit on this page for the duration;
  leaving it hangs up. The page carries only sealed signaling — media flows
  peer-to-peer via the `CallSession` hook, and SDP/ICE payloads are
  encrypted browser-side between the participants' pinned identity keys.
  """

  use VeejrWeb, :live_view

  alias Veejr.{Calls, Messaging, Social}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_count={@pending_count}
      container_class="mx-auto max-w-5xl"
    >
      <div
        id="call-session"
        phx-hook="CallSession"
        phx-update="ignore"
        data-call-id={@call.public_id}
        data-role={@role}
        data-user-id={@current_scope.user.id}
        data-my-key={@current_scope.user.public_key}
        data-peer-key={@peer.public_key}
        data-ice-servers={@ice_servers}
        class="overflow-hidden rounded-[32px] border border-base-300 bg-base-200 shadow-sm"
      >
        <div class="flex items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-5 py-4">
          <div class="min-w-0">
            <h1 class="text-xl font-semibold tracking-tight">
              📞 {@peer.display_name || Veejr.Social.Address.handle(@peer)}
            </h1>
            <div class="mt-0.5 flex flex-wrap items-center gap-2">
              <p data-role="call-status" class="text-sm opacity-70">
                {if @role == "caller", do: "Ringing…", else: "Connecting…"}
              </p>
              <span
                id="call-quality"
                data-role="call-quality"
                class="hidden rounded-full border px-2 py-0.5 text-xs font-medium"
              >
                Measuring…
              </span>
            </div>
          </div>
          <button
            id="hang-up"
            phx-click="hangup"
            class="btn btn-error btn-sm"
          >
            <.icon name="hero-phone-x-mark" class="size-4" /> End call
          </button>
        </div>

        <div class="relative min-h-[60vh] bg-black">
          <video
            data-role="remote-video"
            autoplay
            playsinline
            class="h-[60vh] w-full object-contain"
          ></video>
          <video
            data-role="local-video"
            autoplay
            playsinline
            muted
            class="absolute bottom-4 right-4 h-32 w-44 rounded-lg border border-base-300 bg-base-300 object-cover shadow-lg"
          ></video>
          <p
            data-role="media-error"
            class="absolute inset-x-4 top-4 z-30 mx-auto hidden w-fit max-w-xl rounded-2xl bg-error/95 px-4 py-2 text-center text-sm text-error-content shadow-lg"
          >
          </p>
          <p
            id="call-network-adjustment"
            data-role="call-notice"
            class="absolute bottom-4 left-4 z-10 hidden max-w-sm rounded-2xl border border-white/15 bg-black/75 px-4 py-2 text-sm text-white shadow-lg backdrop-blur"
          >
          </p>

          <div
            id="call-device-setup"
            data-role="device-setup"
            class="absolute inset-0 z-20 flex items-center justify-center overflow-y-auto bg-base-300/95 p-4 backdrop-blur-sm"
          >
            <div class="my-auto grid w-full max-w-3xl overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-2xl md:grid-cols-[1.15fr_0.85fr]">
              <div class="relative min-h-40 bg-black sm:min-h-56 md:min-h-80">
                <video
                  id="call-setup-preview"
                  data-role="setup-video"
                  autoplay
                  playsinline
                  muted
                  class="absolute inset-0 size-full object-cover"
                ></video>
                <div
                  data-role="setup-video-empty"
                  class="absolute inset-0 hidden items-center justify-center p-6 text-center text-sm text-white/70"
                >
                  Camera preview unavailable
                </div>
              </div>

              <div class="flex flex-col justify-center gap-3 p-4 sm:gap-5 sm:p-7">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
                    Private preview
                  </p>
                  <h2
                    data-role="setup-title"
                    class="mt-1 text-xl font-semibold tracking-tight sm:text-2xl"
                  >
                    Check your devices
                  </h2>
                  <p data-role="setup-help" class="mt-2 text-sm opacity-65">
                    Your preview stays on this device. Choose what you want to use, then join.
                  </p>
                </div>

                <div class="space-y-3">
                  <label class="block" for="call-microphone">
                    <span class="mb-1.5 block text-xs font-semibold uppercase tracking-wide opacity-60">
                      Microphone
                    </span>
                    <select
                      id="call-microphone"
                      data-role="microphone-select"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2.5 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                    >
                      <option>Detecting microphones…</option>
                    </select>
                  </label>

                  <label class="block" for="call-camera">
                    <span class="mb-1.5 block text-xs font-semibold uppercase tracking-wide opacity-60">
                      Camera
                    </span>
                    <select
                      id="call-camera"
                      data-role="camera-select"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-3 py-2.5 text-sm outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
                    >
                      <option>Detecting cameras…</option>
                    </select>
                  </label>
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    id="call-join"
                    type="button"
                    data-role="complete-setup"
                    disabled
                    class="btn btn-primary flex-1 rounded-xl"
                  >
                    Preparing devices…
                  </button>
                  <button
                    id="call-retry-media"
                    type="button"
                    data-role="retry-media"
                    class="btn btn-outline hidden rounded-xl"
                  >
                    Retry
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="flex flex-wrap items-center justify-center gap-3 border-t border-base-300 bg-base-100 px-5 py-4">
          <button data-role="toggle-mic" class="btn btn-outline btn-sm">🎙 Mute</button>
          <button data-role="toggle-cam" class="btn btn-outline btn-sm">🎥 Camera off</button>
          <button
            data-role="switch-cam"
            title="Switch to the next camera"
            class="btn btn-outline btn-sm hidden"
          >
            🔄 Camera
          </button>
          <button
            data-role="share-screen"
            title="Share your screen or a window"
            class="btn btn-outline btn-sm hidden"
          >
            🖥 Share screen
          </button>
          <button
            id="call-devices"
            type="button"
            data-role="open-devices"
            title="Choose a microphone or camera"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> Devices
          </button>
        </div>
      </div>

      <p class="mt-3 text-center text-xs opacity-60">
        Audio and video travel directly between you, end-to-end encrypted. Leaving this
        page ends the call and returns you to the conversation.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"public_id" => public_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user

    case Calls.get_call(user, public_id) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That call does not exist.")
         |> push_navigate(to: ~p"/messages", replace: true)}

      {:ok, call} ->
        cond do
          params["reject"] == "1" and call.callee_id == user.id ->
            Calls.decline_call(user, public_id)

            {:ok,
             socket
             |> put_flash(:info, "Call declined.")
             |> push_navigate(to: return_to(params, call, user), replace: true)}

          call.state not in ["ringing", "accepted"] ->
            {:ok,
             socket
             |> put_flash(:error, "That call has already ended.")
             |> push_navigate(to: return_to(params, call, user), replace: true)}

          true ->
            join_and_mount(socket, user, call, params)
        end
    end
  end

  defp join_and_mount(socket, user, call, params) do
    role = if call.caller_id == user.id, do: "caller", else: "callee"
    peer = if role == "caller", do: call.callee, else: call.caller

    if connected?(socket) do
      Calls.subscribe(call)
      Calls.register_presence(call.public_id, user.id)

      cond do
        role == "callee" and call.state == "ringing" ->
          case Calls.join_call(user, call.public_id) do
            {:ok, _call} -> :ok
            # raced with a cancel — the ended broadcast will redirect us
            {:error, _} -> :ok
          end

        role == "caller" and call.state == "accepted" ->
          # The callee already joined — either we reconnected and missed the
          # transient broadcast (common on phones), or they accepted between
          # our dead and connected mounts. Replay it so negotiation starts.
          send(self(), {:call_peer_joined, call.public_id})

        true ->
          :ok
      end
    end

    {:ok,
     assign(socket,
       page_title: "Call",
       call: call,
       role: role,
       peer: peer,
       return_to: return_to(params, call, user),
       ice_servers: Jason.encode!(Veejr.Calls.IceConfig.servers())
     )}
  end

  @impl true
  def handle_event("signal", %{"ciphertext" => ciphertext, "nonce" => nonce}, socket) do
    user = socket.assigns.current_scope.user

    case Calls.signal(user, socket.assigns.call.public_id, ciphertext, nonce) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("hangup", _params, socket) do
    Calls.end_call(socket.assigns.current_scope.user, socket.assigns.call.public_id)

    {:noreply,
     socket
     |> put_flash(:info, "Call ended.")
     |> push_navigate(to: socket.assigns.return_to, replace: true)}
  end

  @impl true
  def handle_info({:call_peer_joined, _id}, socket) do
    {:noreply, push_event(socket, "call:peer_joined", %{})}
  end

  def handle_info({:call_signal, _id, from_id, ciphertext, nonce}, socket) do
    if from_id == socket.assigns.current_scope.user.id do
      {:noreply, socket}
    else
      {:noreply, push_event(socket, "call:signal", %{ciphertext: ciphertext, nonce: nonce})}
    end
  end

  def handle_info({:call_ended, _id, reason}, socket) do
    message =
      case reason do
        "declined" -> "Call declined."
        "missed" -> "Call ended before it was answered."
        _ -> "Call ended."
      end

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: socket.assigns.return_to, replace: true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp return_to(params, call, user) do
    fallback = conversation_path(call, user)

    case URI.parse(params["return_to"] || "") do
      %URI{scheme: nil, host: nil, path: "/messages", fragment: nil} = uri ->
        URI.to_string(uri)

      _uri ->
        fallback
    end
  end

  defp conversation_path(call, user) do
    peer = if call.caller_id == user.id, do: call.callee, else: call.caller
    key = Messaging.conversation_key([Social.Address.handle(peer)])

    ~p"/messages?conversation=#{key}"
  end

  @impl true
  def terminate(_reason, socket) do
    # Leaving the page hangs up — but only after a grace period with no
    # reconnect, so a phone's socket blip doesn't kill the call. Calls that
    # already ended are untouched.
    if call = socket.assigns[:call] do
      Calls.end_call_after_grace(socket.assigns.current_scope.user, call.public_id)
    end

    :ok
  end
end
