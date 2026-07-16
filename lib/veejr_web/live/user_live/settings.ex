defmodule VeejrWeb.UserLive.Settings do
  use VeejrWeb, :live_view

  on_mount {VeejrWeb.UserAuth, :require_sudo_mode}

  alias Veejr.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <section id="push-setup" phx-hook="PushSetup" data-vapid-key={@vapid_key}>
        <h2 class="text-lg font-semibold">Push notifications</h2>
        <p class="mt-1 text-sm opacity-70">
          Get notified on this device even when veejr isn't open. Pushes carry only
          who sent something and what kind — never the content, which stays put until
          you request it.
          <span :if={@push_devices > 0}>
            Currently enabled on {@push_devices} device{if @push_devices != 1, do: "s"}.
          </span>
        </p>
        <button type="button" data-role="push-enable" class="btn btn-outline btn-sm mt-3">
          Enable push on this device
        </button>
        <button
          id="install-app"
          phx-hook="InstallApp"
          type="button"
          class="btn btn-outline btn-sm mt-3 ml-2 hidden"
        >
          📱 Install veejr as an app
        </button>
        <p data-role="push-status" class="mt-2 text-sm opacity-70"></p>
      </section>

      <div class="divider" />

      <section>
        <h2 class="text-lg font-semibold">Your data</h2>
        <p class="mt-1 text-sm opacity-70">
          Download everything: your profile, encrypted key material, friends, groups,
          your full (still encrypted) message history, and your uploaded attachments.
          Use it as a backup, or import it into your own personal veejr instance with <code>mix veejr.import</code>.
        </p>
        <.link href={~p"/export"} class="btn btn-outline btn-sm mt-3">
          ⬇ Export my account
        </.link>
      </section>

      <section :if={Veejr.instance_mode() == :personal}>
        <div class="divider" />
        <h2 class="text-lg font-semibold">Invite someone to this instance</h2>
        <p class="mt-1 text-sm opacity-70">
          Registration on a personal instance is closed, but you can host family or
          friends here: an invite link lets one more person register. Valid for 7 days.
        </p>
        <button phx-click="generate_invite" class="btn btn-outline btn-sm mt-3">
          Generate invite link
        </button>
        <p :if={@invite_url} class="mt-2 text-sm">
          <code class="break-all select-all">{@invite_url}</code>
        </p>
      </section>

      <div class="divider" />

      <section class="rounded-lg border border-error/40 p-4">
        <h2 class="text-lg font-semibold text-error">Danger zone</h2>
        <p :if={@instance_admin} id="admin-account-protection" class="mt-1 text-sm opacity-70">
          This account is the permanent instance administrator and cannot be deleted.
        </p>
        <p :if={!@instance_admin} class="mt-1 text-sm opacity-70">
          Deleting your account is permanent. It also withdraws every message,
          location, and note you ever sent — your data leaves with you. Export first
          if you want to keep your history.
        </p>
        <button
          :if={!@instance_admin}
          phx-click="delete_account"
          data-confirm="Permanently delete your account? This withdraws everything you've sent and cannot be undone."
          class="btn btn-error btn-sm mt-3"
        >
          Delete my account
        </button>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:instance_admin, Accounts.instance_admin?(user))
      |> assign(:invite_url, nil)
      |> assign(:vapid_key, Veejr.Push.WebPush.vapid_public_key())
      |> assign(:push_devices, Veejr.Push.subscription_count(user))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("generate_invite", _params, socket) do
    token = Accounts.generate_invite(socket.assigns.current_scope.user)
    {:noreply, assign(socket, :invite_url, url(~p"/users/register?invite=#{token}"))}
  end

  def handle_event("delete_account", _params, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.delete_user(user) do
      {:ok, _} ->
        # Session tokens are cascade-deleted, so the current session is
        # already invalid — a full redirect lands on the logged-out home page.
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, :instance_admin} ->
        {:noreply, put_flash(socket, :error, "The instance administrator cannot be deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete your account — please try again.")}
    end
  end
end
