defmodule VeejrWeb.AdminLive do
  use VeejrWeb, :live_view

  alias Veejr.{Accounts, Admin}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-7xl space-y-6"
    >
      <.header>
        Instance administration
        <:subtitle>{Veejr.instance_name()} · {Veejr.instance_authority()}</:subtitle>
        <:actions>
          <button phx-click="refresh" class="btn btn-ghost btn-sm" title="Refresh dashboard">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
          <.link navigate={~p"/account"} class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Account
          </.link>
        </:actions>
      </.header>

      <section
        id="admin-health"
        class="flex flex-wrap items-center justify-between gap-3 border-y border-base-300 py-3"
      >
        <div class="flex items-center gap-2">
          <span class={[
            "size-2.5 rounded-full",
            if(healthy?(@snapshot.health), do: "bg-success", else: "bg-error")
          ]} />
          <span class="font-medium">
            {if healthy?(@snapshot.health),
              do: "All monitored services operational",
              else: "Service attention required"}
          </span>
        </div>
        <span class="text-xs opacity-60">
          Updated {Calendar.strftime(@snapshot.captured_at, "%H:%M:%S")} UTC
        </span>
      </section>

      <section aria-labelledby="admin-overview-heading">
        <h2 id="admin-overview-heading" class="text-lg font-semibold">Overview</h2>
        <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.metric id="metric-local-users" label="Local users" value={@snapshot.users.local} />
          <.metric
            id="metric-new-users"
            label="Joined in 7 days"
            value={@snapshot.users.joined_last_7_days}
          />
          <.metric id="metric-envelopes" label="Encrypted items" value={@snapshot.data.envelopes} />
          <.metric
            id="metric-storage"
            label="Attachment storage"
            value={format_bytes(@snapshot.data.blob_bytes)}
            detail={"#{@snapshot.data.blobs} files"}
          />
        </div>
      </section>

      <section id="admin-accounts" aria-labelledby="admin-accounts-heading">
        <div>
          <h2 id="admin-accounts-heading" class="text-lg font-semibold">Local accounts</h2>
          <p class="text-sm opacity-60">Membership and active sign-in sessions</p>
        </div>

        <div class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Account</th>
                <th>Joined</th>
                <th>Status</th>
                <th>Web</th>
                <th>Android</th>
                <th>Last Android activity</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={account <- @accounts} id={"account-#{account.user.id}"}>
                <td>
                  <div class="font-medium">
                    {account.user.display_name || "@#{account.user.username}"}
                  </div>
                  <div
                    :if={account.user.display_name}
                    class="whitespace-nowrap text-xs opacity-60"
                  >
                    @{account.user.username}
                  </div>
                </td>
                <td class="whitespace-nowrap">{format_time(account.user.inserted_at)}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    account_status_class(account.user)
                  ]}>
                    {account_status_label(account.user)}
                  </span>
                </td>
                <td>{account.web_sessions}</td>
                <td>{account.device_sessions}</td>
                <td class="whitespace-nowrap">{format_optional_time(account.last_device_used_at)}</td>
                <td>
                  <span
                    :if={Accounts.instance_admin?(account.user)}
                    class="badge badge-sm badge-neutral whitespace-nowrap"
                  >
                    Instance admin
                  </span>
                  <button
                    :if={
                      not Accounts.instance_admin?(account.user) and
                        account.web_sessions + account.device_sessions > 0
                    }
                    phx-click="revoke_user_sessions"
                    phx-value-id={account.user.id}
                    data-confirm={
                      "Sign @#{account.user.username} out of every web browser and Android device?"
                    }
                    class="btn btn-ghost btn-xs whitespace-nowrap text-error"
                  >
                    Revoke sessions
                  </button>
                  <button
                    :if={
                      not Accounts.instance_admin?(account.user) and is_nil(account.user.suspended_at)
                    }
                    phx-click="suspend_user"
                    phx-value-id={account.user.id}
                    data-confirm={
                      "Suspend @#{account.user.username}? They will be signed out everywhere and unable to sign in until reactivated."
                    }
                    class="btn btn-ghost btn-xs whitespace-nowrap text-error"
                  >
                    Suspend
                  </button>
                  <button
                    :if={not is_nil(account.user.suspended_at)}
                    phx-click="reactivate_user"
                    phx-value-id={account.user.id}
                    class="btn btn-ghost btn-xs whitespace-nowrap text-success"
                  >
                    Reactivate
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="admin-invitations" aria-labelledby="admin-invitations-heading">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 id="admin-invitations-heading" class="text-lg font-semibold">Invitations</h2>
            <p class="text-sm opacity-60">Most recent tracked invitations</p>
          </div>
          <.link navigate={~p"/invites/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-qr-code" class="size-4" /> New invitation
          </.link>
        </div>

        <p :if={@invitations == []} class="mt-3 border-y border-base-300 py-5 text-sm opacity-60">
          No tracked invitations yet.
        </p>

        <div :if={@invitations != []} class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Created</th>
                <th>Inviter</th>
                <th>Status</th>
                <th>Expires / joined</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={invitation <- @invitations} id={"invitation-#{invitation.id}"}>
                <td class="whitespace-nowrap">{format_time(invitation.inserted_at)}</td>
                <td class="whitespace-nowrap">@{invitation.inviter.username}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    invitation_status_class(Admin.invitation_status(invitation))
                  ]}>
                    {invitation_status_label(Admin.invitation_status(invitation))}
                  </span>
                </td>
                <td class="whitespace-nowrap text-sm">
                  <%= if invitation.accepted_by do %>
                    @{invitation.accepted_by.username} · {format_time(invitation.accepted_at)}
                  <% else %>
                    {format_time(invitation.expires_at)}
                  <% end %>
                </td>
                <td class="text-right">
                  <button
                    :if={Admin.invitation_status(invitation) == :active}
                    phx-click="revoke_invitation"
                    phx-value-id={invitation.id}
                    data-confirm="Revoke this invitation? Its QR code and link will stop working immediately."
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <div class="grid gap-6 lg:grid-cols-2">
        <section aria-labelledby="admin-operations-heading">
          <h2 id="admin-operations-heading" class="text-lg font-semibold">Operations</h2>
          <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
            <.row
              label="Encrypted items awaiting recipient approval"
              value={@snapshot.data.pending_notifications}
            />
            <.row label="Active invitations" value={@snapshot.operations.active_invitations} />
            <.row label="Federation retry queue" value={@snapshot.operations.federation_queue} />
            <.row label="Pinned peer instances" value={@snapshot.operations.pinned_peers} />
            <.row label="Remote contacts" value={@snapshot.users.remote} />
          </dl>
        </section>

        <section aria-labelledby="admin-system-heading">
          <h2 id="admin-system-heading" class="text-lg font-semibold">System</h2>
          <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
            <.status_row label="Database" status={@snapshot.health.database} />
            <.status_row label="Web endpoint" status={@snapshot.health.endpoint} />
            <.status_row label="Federation worker" status={@snapshot.health.federation_outbox} />
            <.row label="Veejr" value={@snapshot.software.veejr} />
            <.row
              label="Runtime"
              value={"Elixir #{@snapshot.software.elixir} · OTP #{@snapshot.software.otp}"}
            />
            <.row label="Database engine" value={@snapshot.software.database} />
          </dl>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.instance_admin?(socket.assigns.current_scope.user) do
      {:ok, socket |> assign(page_title: "Instance administration") |> load_dashboard()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only the instance administrator can access that page.")
       |> redirect(to: ~p"/contacts")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    socket =
      case Admin.revoke_invitation(socket.assigns.current_scope.user, id) do
        {:ok, _invitation} ->
          put_flash(socket, :info, "Invitation revoked.")

        {:error, :not_revocable} ->
          put_flash(socket, :error, "That invitation is no longer active.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not revoke that invitation.")
      end

    {:noreply, load_dashboard(socket)}
  end

  def handle_event("revoke_user_sessions", %{"id" => id}, socket) do
    socket =
      case Admin.revoke_user_sessions(socket.assigns.current_scope.user, id) do
        {:ok, result} ->
          VeejrWeb.UserAuth.disconnect_sessions(result.web_tokens)

          put_flash(
            socket,
            :info,
            "Revoked #{result.web_count} web and #{result.device_count} Android sessions for @#{result.user.username}."
          )

        {:error, :protected_admin} ->
          put_flash(
            socket,
            :error,
            "The instance administrator's sessions cannot be revoked here."
          )

        {:error, _reason} ->
          put_flash(socket, :error, "Could not revoke those sessions.")
      end

    {:noreply, load_dashboard(socket)}
  end

  def handle_event("suspend_user", %{"id" => id}, socket) do
    socket =
      case Admin.suspend_user(socket.assigns.current_scope.user, id) do
        {:ok, result} ->
          VeejrWeb.UserAuth.disconnect_sessions(result.web_tokens)

          put_flash(
            socket,
            :info,
            "@#{result.user.username} was suspended and signed out everywhere."
          )

        {:error, :protected_admin} ->
          put_flash(socket, :error, "The instance administrator cannot be suspended.")

        {:error, :already_suspended} ->
          put_flash(socket, :error, "That account is already suspended.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not suspend that account.")
      end

    {:noreply, load_dashboard(socket)}
  end

  def handle_event("reactivate_user", %{"id" => id}, socket) do
    socket =
      case Admin.reactivate_user(socket.assigns.current_scope.user, id) do
        {:ok, user} ->
          put_flash(socket, :info, "@#{user.username} can sign in again.")

        {:error, :not_suspended} ->
          put_flash(socket, :error, "That account is already active.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not reactivate that account.")
      end

    {:noreply, load_dashboard(socket)}
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300 bg-base-100 p-4">
      <p class="text-xs font-medium uppercase opacity-60">{@label}</p>
      <p class="mt-2 text-2xl font-semibold">{@value}</p>
      <p :if={@detail} class="mt-1 text-xs opacity-60">{@detail}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 py-3 text-sm">
      <dt class="opacity-70">{@label}</dt>
      <dd class="text-right font-medium">{@value}</dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :status, :atom, required: true

  defp status_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 py-3 text-sm">
      <dt class="opacity-70">{@label}</dt>
      <dd class={["badge badge-sm", if(@status == :ok, do: "badge-success", else: "badge-error")]}>
        {if @status == :ok, do: "Operational", else: "Unavailable"}
      </dd>
    </div>
    """
  end

  defp healthy?(health), do: Enum.all?(health, fn {_service, status} -> status == :ok end)

  defp load_dashboard(socket) do
    assign(socket,
      snapshot: Admin.snapshot(),
      accounts: Admin.list_local_accounts(),
      invitations: Admin.list_invitations()
    )
  end

  defp invitation_status_label(:active), do: "Active"
  defp invitation_status_label(:accepted), do: "Accepted"
  defp invitation_status_label(:expired), do: "Expired"
  defp invitation_status_label(:revoked), do: "Revoked"

  defp invitation_status_class(:active), do: "badge-success"
  defp invitation_status_class(:accepted), do: "badge-info"
  defp invitation_status_class(:expired), do: "badge-neutral"
  defp invitation_status_class(:revoked), do: "badge-error"

  defp account_status_label(%{suspended_at: suspended_at}) when not is_nil(suspended_at),
    do: "Suspended"

  defp account_status_label(%{confirmed_at: nil}), do: "Pending"
  defp account_status_label(_user), do: "Confirmed"

  defp account_status_class(%{suspended_at: suspended_at}) when not is_nil(suspended_at),
    do: "badge-error"

  defp account_status_class(%{confirmed_at: nil}), do: "badge-warning"
  defp account_status_class(_user), do: "badge-success"

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")

  defp format_optional_time(nil), do: "Never"
  defp format_optional_time(datetime), do: format_time(datetime)

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
