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

      <div class="grid gap-6 lg:grid-cols-2">
        <section aria-labelledby="admin-operations-heading">
          <h2 id="admin-operations-heading" class="text-lg font-semibold">Operations</h2>
          <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
            <.row label="Pending encrypted approvals" value={@snapshot.data.pending_notifications} />
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
      {:ok, assign(socket, page_title: "Instance administration", snapshot: Admin.snapshot())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only the instance administrator can access that page.")
       |> redirect(to: ~p"/contacts")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :snapshot, Admin.snapshot())}
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

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
