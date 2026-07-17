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
          <.metric
            id="metric-email-failures"
            label="Email failures"
            value={@snapshot.operations.email_failures}
          />
          <.metric
            id="metric-federation-queue"
            label="Federation retries"
            value={@snapshot.operations.federation_queue}
          />
        </div>
      </section>

      <section id="admin-settings" aria-labelledby="admin-settings-heading">
        <div>
          <h2 id="admin-settings-heading" class="text-lg font-semibold">Instance settings</h2>
          <p class="text-sm opacity-60">Registration, storage, retention, and mail defaults</p>
        </div>

        <.form
          for={@settings_form}
          id="instance-settings-form"
          phx-change="validate_settings"
          phx-submit="save_settings"
          class="mt-3 space-y-4 border-y border-base-300 py-4"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@settings_form[:name]} label="Instance name" />
            <.input
              field={@settings_form[:registration_policy]}
              type="select"
              label="Registration policy"
              options={[
                {"Use deployment mode", "mode_default"},
                {"Open registration", "open"},
                {"Invitation only", "invite_only"},
                {"Closed", "closed"}
              ]}
            />
          </div>

          <.input field={@settings_form[:description]} type="textarea" label="Instance description" />

          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              field={@settings_form[:invitation_lifetime_days]}
              type="number"
              min="1"
              max="30"
              label="Invitation lifetime (days)"
            />
            <.input
              field={@settings_form[:max_upload_mb]}
              type="number"
              min="1"
              max="100"
              label="Maximum upload (MB)"
            />
            <.input
              field={@settings_form[:storage_quota_mb]}
              type="number"
              min="1"
              label="Storage quota (MB)"
              placeholder="Unlimited"
            />
            <.input
              field={@settings_form[:default_retention_hours]}
              type="number"
              min="1"
              max="720"
              label="Default retention (hours)"
              placeholder="No default"
            />
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@settings_form[:mail_from_name]} label="Mail sender name" />
            <.input
              field={@settings_form[:mail_from_address]}
              type="email"
              label="Mail sender address"
            />
          </div>

          <dl class="grid gap-3 text-sm sm:grid-cols-2">
            <div>
              <dt class="opacity-60">Deployment mode</dt>
              <dd class="font-medium">{Veejr.instance_mode()}</dd>
            </div>
            <div>
              <dt class="opacity-60">Public federation authority</dt>
              <dd class="font-medium">{Veejr.instance_authority()}</dd>
            </div>
          </dl>

          <div class="flex flex-wrap gap-2">
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="size-4" /> Save settings
            </button>
            <button type="button" phx-click="test_mail" class="btn btn-outline btn-sm">
              <.icon name="hero-envelope" class="size-4" /> Send test email
            </button>
          </div>
        </.form>
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
                <th>Last sign-in</th>
                <th>Storage</th>
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
                <td class="whitespace-nowrap">
                  {format_optional_time(last_account_activity(account))}
                </td>
                <td class="whitespace-nowrap">{format_bytes(account.storage_bytes)}</td>
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

      <section id="admin-account-moves" aria-labelledby="admin-account-moves-heading">
        <div>
          <h2 id="admin-account-moves-heading" class="text-lg font-semibold">Account moves</h2>
          <p class="text-sm opacity-60">Test and move a member into a separately managed instance</p>
        </div>

        <div :if={!@account_moves_enabled} class="alert alert-warning mt-3 text-sm">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Account moves are disabled until the host provisioner token is configured.</span>
        </div>

        <.form
          :if={@account_moves_enabled and movable_account_options(@accounts) != []}
          for={@move_form}
          id="account-move-form"
          phx-submit="create_account_move"
          class="mt-3 grid gap-3 border-y border-base-300 py-4 md:grid-cols-2 lg:grid-cols-5"
        >
          <.input
            field={@move_form[:user_id]}
            type="select"
            label="Member"
            prompt="Choose a member"
            options={movable_account_options(@accounts)}
            required
          />
          <.input
            field={@move_form[:target_host]}
            label="New hostname"
            placeholder="alice.example.com"
            required
          />
          <.input
            field={@move_form[:instance_name]}
            label="Instance name"
            placeholder="Alice's Veejr"
            required
          />
          <.input
            field={@move_form[:instance_mode]}
            type="select"
            label="Mode"
            options={[{"Personal", "personal"}, {"Community", "community"}]}
          />
          <div class="flex items-end">
            <button type="submit" class="btn btn-primary btn-sm w-full">
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Start test
            </button>
          </div>
        </.form>

        <p :if={@account_moves == []} class="mt-3 border-y border-base-300 py-5 text-sm opacity-60">
          No account moves have been started.
        </p>

        <div :if={@account_moves != []} class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Member</th><th>Target</th><th>Status</th><th>Export</th><th>
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={move <- @account_moves} id={"account-move-#{move.id}"}>
                <td class="font-medium">@{move.username}</td>
                <td>
                  <div>{move.instance_name}</div><div class="text-xs opacity-60">
                    {move.target_host}
                  </div>
                </td>
                <td>
                  <span class={["badge badge-sm whitespace-nowrap", move_status_class(move.status)]}>{move_status_label(
                    move.status
                  )}</span><div :if={move.error} class="mt-1 max-w-72 text-xs text-error">
                    {move.error}
                  </div>
                </td>
                <td class="whitespace-nowrap text-xs">
                  {move.expected_envelopes} items / {move.expected_blobs} files
                </td>
                <td class="whitespace-nowrap text-right">
                  <button
                    :if={move.status == "test_verified"}
                    phx-click="approve_account_move"
                    phx-value-id={move.id}
                    data-confirm={"Suspend @#{move.username}, sign them out, and begin final provisioning?"}
                    class="btn btn-primary btn-xs"
                  >Approve cutover</button>
                  <button
                    :if={
                      move.status in ["test_failed", "provision_failed", "testing", "provisioning"]
                    }
                    phx-click="retry_account_move"
                    phx-value-id={move.id}
                    data-confirm={
                      if move.status in ["testing", "provisioning"],
                        do:
                          "Retry only after confirming the host provisioner is no longer processing this job. Continue?",
                        else: nil
                    }
                    class="btn btn-outline btn-xs"
                  >Retry</button>
                  <button
                    :if={move.status == "target_verified"}
                    phx-click="finalize_account_move"
                    phx-value-id={move.id}
                    data-confirm={"Permanently delete @#{move.username} from this instance? Confirm the new site works first. This cannot be undone."}
                    class="btn btn-error btn-xs"
                  >Finalize</button>
                  <button
                    :if={
                      move.status in [
                        "awaiting_test",
                        "test_verified",
                        "test_failed",
                        "awaiting_final_import",
                        "provision_failed"
                      ]
                    }
                    phx-click="cancel_account_move"
                    phx-value-id={move.id}
                    data-confirm="Cancel this move? A member suspended for cutover will be reactivated."
                    class="btn btn-ghost btn-xs"
                  >Cancel</button>
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
                  <button
                    :if={Admin.invitation_status(invitation) == :active}
                    phx-click="expire_invitation"
                    phx-value-id={invitation.id}
                    data-confirm="Expire this invitation immediately?"
                    class="btn btn-ghost btn-xs"
                  >
                    Expire
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="admin-audit" aria-labelledby="admin-audit-heading">
        <div>
          <h2 id="admin-audit-heading" class="text-lg font-semibold">Recent admin activity</h2>
          <p class="text-sm opacity-60">Append-only security and access actions</p>
        </div>

        <p :if={@audit_events == []} class="mt-3 border-y border-base-300 py-5 text-sm opacity-60">
          No administrator actions recorded yet.
        </p>

        <div :if={@audit_events != []} class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Administrator</th>
                <th>Action</th>
                <th>Target</th>
                <th>Sessions ended</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @audit_events} id={"audit-event-#{event.id}"}>
                <td class="whitespace-nowrap">{format_time(event.inserted_at)}</td>
                <td class="whitespace-nowrap">@{event.actor.username}</td>
                <td class="whitespace-nowrap">{audit_action_label(event.action)}</td>
                <td class="whitespace-nowrap">{audit_target_label(event)}</td>
                <td>{audit_session_count(event)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="admin-peers" aria-labelledby="admin-peers-heading">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 id="admin-peers-heading" class="text-lg font-semibold">Federation peers</h2>
            <p class="text-sm opacity-60">Pinned remote instances and traffic controls</p>
          </div>
          <button
            :if={@snapshot.operations.federation_queue > 0}
            phx-click="retry_federation"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry pending
          </button>
        </div>

        <p :if={@peers == []} class="mt-3 border-y border-base-300 py-5 text-sm opacity-60">
          No remote instances have been pinned yet.
        </p>

        <div :if={@peers != []} class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Authority</th>
                <th>First pinned</th>
                <th>Status</th>
                <th>Pending</th>
                <th>Last failure</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @peers} id={"peer-#{entry.peer.id}"}>
                <td class="font-medium">{entry.peer.authority}</td>
                <td class="whitespace-nowrap">{format_time(entry.peer.inserted_at)}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    if(entry.peer.blocked_at, do: "badge-error", else: "badge-success")
                  ]}>
                    {if entry.peer.blocked_at, do: "Blocked", else: "Allowed"}
                  </span>
                </td>
                <td>{entry.pending_deliveries}</td>
                <td class="max-w-72 truncate text-xs" title={entry.last_error}>
                  {entry.last_error || "-"}
                </td>
                <td class="text-right">
                  <button
                    :if={is_nil(entry.peer.blocked_at)}
                    phx-click="block_peer"
                    phx-value-id={entry.peer.id}
                    data-confirm={
                      "Block #{entry.peer.authority}? Inbound and outbound federation traffic will stop, and queued notifications to it will be discarded."
                    }
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Block
                  </button>
                  <button
                    :if={not is_nil(entry.peer.blocked_at)}
                    phx-click="unblock_peer"
                    phx-value-id={entry.peer.id}
                    class="btn btn-ghost btn-xs text-success"
                  >
                    Unblock
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@pending_key_changes != []} class="mt-4 border-y border-warning/40 py-3">
          <h3 class="text-sm font-semibold">Pending remote key changes</h3>
          <p class="mt-1 text-xs opacity-60">
            Each affected contact must approve their new pinned key.
          </p>
          <ul class="mt-2 flex flex-wrap gap-2">
            <li :for={user <- @pending_key_changes} class="badge badge-warning badge-sm">
              @{user.username}@{user.host}
            </li>
          </ul>
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
            <.row label="Recorded email failures" value={@snapshot.operations.email_failures} />
            <.row label="Pending remote key changes" value={@snapshot.operations.pending_key_changes} />
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

      <section
        :if={@operational_failures != []}
        id="admin-failures"
        aria-labelledby="admin-failures-heading"
      >
        <h2 id="admin-failures-heading" class="text-lg font-semibold">Recent delivery failures</h2>
        <div class="mt-3 overflow-x-auto border-y border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Time</th><th>Channel</th><th>Operation</th><th>Error</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={failure <- @operational_failures}>
                <td class="whitespace-nowrap">{format_time(failure.inserted_at)}</td>
                <td>{failure.channel}</td>
                <td>{failure.operation}</td>
                <td class="max-w-xl truncate text-xs" title={failure.error}>{failure.error}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
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

  def handle_event("validate_settings", %{"settings" => params}, socket) do
    form =
      params
      |> Admin.change_instance_settings()
      |> Map.put(:action, :validate)
      |> to_form(as: "settings")

    {:noreply, assign(socket, settings_form: form)}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Admin.update_instance_settings(socket.assigns.current_scope.user, params) do
      {:ok, _settings} ->
        {:noreply, socket |> put_flash(:info, "Instance settings saved.") |> load_dashboard()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset, as: "settings"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save instance settings.")}
    end
  end

  def handle_event("test_mail", _params, socket) do
    socket =
      case Admin.test_mail_delivery(socket.assigns.current_scope.user) do
        {:ok, _email} -> put_flash(socket, :info, "Test email sent to the administrator account.")
        {:error, _reason} -> put_flash(socket, :error, "The test email could not be delivered.")
      end

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

  def handle_event("expire_invitation", %{"id" => id}, socket) do
    socket =
      case Admin.expire_invitation(socket.assigns.current_scope.user, id) do
        {:ok, _invitation} ->
          put_flash(socket, :info, "Invitation expired.")

        {:error, :not_expirable} ->
          put_flash(socket, :error, "That invitation is no longer active.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not expire that invitation.")
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

  def handle_event(
        "create_account_move",
        %{"account_move" => %{"user_id" => user_id} = params},
        socket
      ) do
    case Veejr.AccountMoves.create(socket.assigns.current_scope.user, user_id, params) do
      {:ok, _move} ->
        {:noreply, socket |> put_flash(:info, "The test import is queued.") |> load_dashboard()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, move_form: to_form(changeset, as: "account_move"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, account_move_error(reason))}
    end
  end

  def handle_event("approve_account_move", %{"id" => id}, socket) do
    case Veejr.AccountMoves.approve_cutover(socket.assigns.current_scope.user, id) do
      {:ok, %{sessions: sessions}} ->
        VeejrWeb.UserAuth.disconnect_sessions(sessions.web_tokens)

        {:noreply,
         socket
         |> put_flash(:info, "The member is suspended and final provisioning is queued.")
         |> load_dashboard()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, account_move_error(reason))}
    end
  end

  def handle_event("retry_account_move", %{"id" => id}, socket) do
    account_move_action(
      socket,
      Veejr.AccountMoves.retry(socket.assigns.current_scope.user, id),
      "The move was queued again."
    )
  end

  def handle_event("cancel_account_move", %{"id" => id}, socket) do
    account_move_action(
      socket,
      Veejr.AccountMoves.cancel(socket.assigns.current_scope.user, id),
      "The account move was cancelled."
    )
  end

  def handle_event("finalize_account_move", %{"id" => id}, socket) do
    account_move_action(
      socket,
      Veejr.AccountMoves.finalize(socket.assigns.current_scope.user, id),
      "The source account was deleted. The move is complete."
    )
  end

  def handle_event("block_peer", %{"id" => id}, socket) do
    socket =
      case Admin.block_peer(socket.assigns.current_scope.user, id) do
        {:ok, result} ->
          put_flash(
            socket,
            :info,
            "Blocked #{result.peer.authority}; discarded #{result.outbound_deliveries_dropped} queued deliveries."
          )

        {:error, :already_blocked} ->
          put_flash(socket, :error, "That peer is already blocked.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not block that peer.")
      end

    {:noreply, load_dashboard(socket)}
  end

  def handle_event("unblock_peer", %{"id" => id}, socket) do
    socket =
      case Admin.unblock_peer(socket.assigns.current_scope.user, id) do
        {:ok, peer} ->
          put_flash(socket, :info, "Federation with #{peer.authority} is allowed again.")

        {:error, :not_blocked} ->
          put_flash(socket, :error, "That peer is already allowed.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not unblock that peer.")
      end

    {:noreply, load_dashboard(socket)}
  end

  def handle_event("retry_federation", _params, socket) do
    socket =
      case Admin.retry_federation(socket.assigns.current_scope.user) do
        {:ok, result} ->
          put_flash(
            socket,
            :info,
            "Retried #{result.scheduled} deliveries: #{result.succeeded} succeeded, #{result.remaining} remain queued."
          )

        {:error, _reason} ->
          put_flash(socket, :error, "Could not retry federation deliveries.")
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
      account_moves: Veejr.AccountMoves.list_account_moves(),
      account_moves_enabled: Veejr.AccountMoves.enabled?(),
      move_form:
        to_form(Veejr.AccountMoves.change_account_move(%{"instance_mode" => "personal"}),
          as: "account_move"
        ),
      invitations: Admin.list_invitations(),
      audit_events: Admin.list_audit_events(),
      peers: Admin.list_peers(),
      pending_key_changes: Admin.list_pending_key_changes(),
      operational_failures: Admin.list_operational_failures(),
      settings_form: to_form(Admin.change_instance_settings(), as: "settings")
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

  defp audit_action_label("account.reactivated"), do: "Account reactivated"
  defp audit_action_label("account.suspended"), do: "Account suspended"
  defp audit_action_label("account_move.cancelled"), do: "Account move cancelled"
  defp audit_action_label("account_move.created"), do: "Account move started"
  defp audit_action_label("account_move.cutover_approved"), do: "Account move cutover approved"
  defp audit_action_label("account_move.failed"), do: "Account move failed"
  defp audit_action_label("account_move.finalized"), do: "Account move finalized"
  defp audit_action_label("account_move.retried"), do: "Account move retried"
  defp audit_action_label("account_move.target_verified"), do: "Account move target verified"
  defp audit_action_label("account_move.test_verified"), do: "Account move test verified"
  defp audit_action_label("federation.retried"), do: "Federation retried"
  defp audit_action_label("instance.mail_tested"), do: "Mail tested"
  defp audit_action_label("instance.settings_updated"), do: "Settings updated"
  defp audit_action_label("invitation.expired"), do: "Invitation expired"
  defp audit_action_label("invitation.revoked"), do: "Invitation revoked"
  defp audit_action_label("peer.blocked"), do: "Peer blocked"
  defp audit_action_label("peer.unblocked"), do: "Peer unblocked"
  defp audit_action_label("sessions.revoked"), do: "Sessions revoked"

  defp audit_target_label(%{target_type: "user", target_id: id, details: details}) do
    case details["username"] do
      username when is_binary(username) -> "@#{username}"
      _ -> "User ##{id}"
    end
  end

  defp audit_target_label(%{target_type: "invitation", target_id: id}),
    do: "Invitation ##{id}"

  defp audit_target_label(%{target_type: "peer", target_id: id, details: details}) do
    details["authority"] || "Peer ##{id}"
  end

  defp audit_target_label(%{target_type: "instance"}), do: "Instance"

  defp audit_target_label(%{target_type: "account_move", target_id: id, details: details}) do
    case details["username"] do
      username when is_binary(username) -> "@#{username} to #{details["target_host"]}"
      _ -> "Account move ##{id}"
    end
  end

  defp audit_session_count(%{details: details}) do
    web = details["web_sessions"] || 0
    devices = details["device_sessions"] || 0

    if web + devices == 0, do: "-", else: "#{web} web / #{devices} Android"
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")

  defp format_optional_time(nil), do: "Never"
  defp format_optional_time(datetime), do: format_time(datetime)

  defp last_account_activity(account) do
    [account.last_web_authenticated_at, account.last_device_used_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp movable_account_options(accounts) do
    for %{user: user} <- accounts,
        not Accounts.instance_admin?(user),
        do: {"@#{user.username}", user.id}
  end

  defp move_status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp move_status_class(status) when status in ["test_verified", "target_verified", "finalized"],
    do: "badge-success"

  defp move_status_class(status) when status in ["test_failed", "provision_failed"],
    do: "badge-error"

  defp move_status_class(status) when status in ["testing", "provisioning"], do: "badge-info"
  defp move_status_class(_status), do: "badge-neutral"

  defp account_move_action(socket, {:ok, _move}, message),
    do: {:noreply, socket |> put_flash(:info, message) |> load_dashboard()}

  defp account_move_action(socket, {:error, reason}, _message),
    do: {:noreply, put_flash(socket, :error, account_move_error(reason))}

  defp account_move_error(:provisioner_disabled),
    do: "Configure the host provisioner before starting a move."

  defp account_move_error(:protected_admin), do: "The instance administrator cannot be moved."
  defp account_move_error(:move_in_progress), do: "That member already has an active move."

  defp account_move_error(:invalid_state),
    do: "That move has already advanced or cannot be changed now."

  defp account_move_error(_reason), do: "The account move could not be updated."
end
