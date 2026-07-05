defmodule VeejrWeb.KeysLive do
  use VeejrWeb, :live_view

  alias Veejr.{Accounts, Federation, Messaging, Repo}

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

          <div class="divider" />

          <section>
            <h2 class="text-lg font-semibold">Change passphrase</h2>
            <p class="text-sm opacity-70 mt-1">
              Re-wraps your secret key under a new passphrase. Your keypair — and all
              your history — is unchanged.
            </p>
            <form
              id="key-rewrap"
              phx-hook="KeyRewrap"
              data-user-id={@user.id}
              data-enc-secret-key={@user.enc_secret_key}
              data-key-salt={@user.key_salt}
              data-key-nonce={@user.key_nonce}
              class="mt-3 space-y-2"
            >
              <p data-role="error" class="hidden text-error text-sm"></p>
              <input
                type="password"
                data-role="current"
                placeholder="current passphrase"
                class="input input-sm w-full"
                required
              />
              <input
                type="password"
                data-role="next"
                placeholder="new passphrase (min 8 characters)"
                class="input input-sm w-full"
                required
              />
              <input
                type="password"
                data-role="confirm"
                placeholder="confirm new passphrase"
                class="input input-sm w-full"
                required
              />
              <button type="submit" class="btn btn-sm">Change passphrase</button>
            </form>
          </section>

          <div class="divider" />

          <section>
            <h2 class="text-lg font-semibold">Rotate keys</h2>
            <p class="text-sm opacity-70 mt-1">
              Generates a brand-new keypair — do this if you suspect your keys were
              compromised. Your history is re-encrypted to the new key in this
              browser, and friends on other instances are asked to confirm your new
              key before they can reach you again.
            </p>
            <form
              id="key-rotate"
              phx-hook="KeyRotate"
              data-user-id={@user.id}
              data-enc-secret-key={@user.enc_secret_key}
              data-key-salt={@user.key_salt}
              data-key-nonce={@user.key_nonce}
              class="mt-3 space-y-2"
            >
              <p data-role="error" class="hidden text-error text-sm"></p>
              <input
                type="password"
                data-role="current"
                placeholder="current passphrase"
                class="input input-sm w-full"
                required
              />
              <input
                type="password"
                data-role="next"
                placeholder="new passphrase (min 8 characters)"
                class="input input-sm w-full"
                required
              />
              <button type="submit" class="btn btn-warning btn-sm">Rotate my keys</button>
            </form>
          </section>

          <div class="divider" />

          <details class="rounded-lg border border-error/40 p-4">
            <summary class="cursor-pointer font-semibold text-error">
              Lost your passphrase?
            </summary>
            <p class="text-sm opacity-70 mt-2">
              Without the passphrase your history cannot be recovered — that is the
              point of end-to-end encryption. Resetting creates fresh keys so you can
              keep using veejr, but <strong>everything you've received so far is
              permanently deleted</strong>. Friends on other instances must confirm
              your new key.
            </p>
            <form id="key-reset" phx-hook="KeyReset" data-user-id={@user.id} class="mt-3 space-y-2">
              <p data-role="error" class="hidden text-error text-sm"></p>
              <input
                type="password"
                data-role="next"
                placeholder="new passphrase (min 8 characters)"
                class="input input-sm w-full"
                required
              />
              <input
                type="password"
                data-role="confirm"
                placeholder="confirm new passphrase"
                class="input input-sm w-full"
                required
              />
              <button type="submit" class="btn btn-error btn-sm">
                Reset keys and delete received history
              </button>
            </form>
          </details>
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
       return_to: params["return_to"],
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
    {:noreply, push_navigate(socket, to: socket.assigns.return_to || ~p"/")}
  end

  def handle_event("rewrap_keys", params, socket) do
    case Accounts.rewrap_user_keys(socket.assigns.user, params) do
      {:ok, user} ->
        {:reply, %{ok: true},
         socket |> assign(user: user) |> put_flash(:info, "Passphrase changed.")}

      {:error, _} ->
        {:reply, %{error: "Could not change the passphrase."}, socket}
    end
  end

  def handle_event("list_resealable", _params, socket) do
    {:reply, %{envelopes: Messaging.list_resealable(socket.assigns.user)}, socket}
  end

  def handle_event("rotate_keys", %{"keys" => keys, "envelopes" => envelopes} = params, socket) do
    result =
      Repo.transaction(fn ->
        {:ok, user} = Accounts.rotate_user_keys(socket.assigns.user, keys)
        {:ok, count} = Messaging.reseal_envelopes(user, envelopes)
        {user, count}
      end)

    case result do
      {:ok, {user, count}} ->
        Federation.announce_key_update(user)
        unreadable = params["unreadable"] || 0

        message =
          "Keys rotated; #{count} items re-encrypted." <>
            if(unreadable > 0,
              do: " #{unreadable} items could not be read and were left as-is.",
              else: ""
            )

        {:reply, %{ok: true}, socket |> assign(user: user) |> put_flash(:info, message)}

      _ ->
        {:reply, %{error: "Rotation failed — nothing was changed."}, socket}
    end
  end

  def handle_event("reset_keys", %{"keys" => keys}, socket) do
    result =
      Repo.transaction(fn ->
        {:ok, _count} = Messaging.purge_received_envelopes(socket.assigns.user)
        {:ok, user} = Accounts.rotate_user_keys(socket.assigns.user, keys)
        user
      end)

    case result do
      {:ok, user} ->
        Federation.announce_key_update(user)

        {:reply, %{ok: true},
         socket
         |> assign(user: user)
         |> put_flash(:info, "Fresh keys created. Received history was deleted.")}

      _ ->
        {:reply, %{error: "Reset failed — nothing was changed."}, socket}
    end
  end
end
