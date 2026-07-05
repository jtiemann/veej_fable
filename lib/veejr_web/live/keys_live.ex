defmodule VeejrWeb.KeysLive do
  use VeejrWeb, :live_view

  alias Veejr.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md">
        <%= if @user.public_key do %>
          <.header>
            Unlock your keys
            <:subtitle>
              Your secret key is stored encrypted. Enter your passphrase to unlock it
              for this browser session. The passphrase never leaves this device.
            </:subtitle>
          </.header>

          <form
            id="key-unlock"
            phx-hook="KeyUnlock"
            data-user-id={@user.id}
            data-enc-secret-key={@user.enc_secret_key}
            data-key-salt={@user.key_salt}
            data-key-nonce={@user.key_nonce}
            data-return-to={@return_to}
            class="mt-6 space-y-4"
          >
            <p data-role="error" class="hidden text-error text-sm"></p>
            <label class="fieldset-label">Encryption passphrase</label>
            <input
              type="password"
              data-role="passphrase"
              class="input w-full"
              autocomplete="off"
              required
            />
            <button type="submit" class="btn btn-primary w-full">Unlock</button>
          </form>

          <div class="mt-8 text-sm opacity-70">
            <p>Public key fingerprint:</p>
            <code class="break-all">{@user.public_key}</code>
          </div>

          <button
            id="key-lock"
            phx-hook="KeyLock"
            data-user-id={@user.id}
            class="btn btn-ghost btn-sm mt-6"
          >
            Lock this session
          </button>
        <% else %>
          <.header>
            Create your encryption keys
            <:subtitle>
              veejr encrypts everything end-to-end. Your keypair is generated here in
              your browser; the server only receives your public key and a copy of your
              secret key sealed with the passphrase below. Without the passphrase,
              nobody — including the server — can read your messages.
            </:subtitle>
          </.header>

          <form id="key-setup" phx-hook="KeySetup" data-user-id={@user.id} class="mt-6 space-y-4">
            <p data-role="error" class="hidden text-error text-sm"></p>
            <label class="fieldset-label">Encryption passphrase (min 8 characters)</label>
            <input
              type="password"
              data-role="passphrase"
              class="input w-full"
              autocomplete="new-password"
              required
            />
            <label class="fieldset-label">Confirm passphrase</label>
            <input
              type="password"
              data-role="confirm"
              class="input w-full"
              autocomplete="new-password"
              required
            />
            <button type="submit" class="btn btn-primary w-full">Generate my keys</button>
            <p class="text-xs opacity-70">
              Write your passphrase down. If you lose it, previously received messages
              cannot be recovered — that is the point.
            </p>
          </form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       user: socket.assigns.current_scope.user,
       return_to: params["return_to"] || "/",
       page_title: "Keys"
     )}
  end

  @impl true
  def handle_event("keys_generated", params, socket) do
    case Accounts.setup_user_keys(socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Encryption keys created. Welcome to veejr!")
         |> push_navigate(to: ~p"/")}

      {:error, :keys_already_set} ->
        {:noreply, put_flash(socket, :error, "Keys are already set for this account.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not store keys — please try again.")}
    end
  end

  def handle_event("unlocked", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end
end
