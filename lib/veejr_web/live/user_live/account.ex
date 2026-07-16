defmodule VeejrWeb.UserLive.Account do
  use VeejrWeb, :live_view

  alias Veejr.Push

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-8"
    >
      <section class="space-y-2">
        <p class="text-sm font-medium uppercase tracking-[0.2em] text-primary">Account</p>
        <.header>
          {@current_scope.user.username}
          <:subtitle>Manage your account, security, and device preferences.</:subtitle>
        </.header>
      </section>

      <section
        id="account-status"
        phx-hook="AccountStatus"
        data-user-id={@current_scope.user.id}
        data-has-identity={not is_nil(@current_scope.user.public_key)}
        class="rounded-2xl border border-base-300/70 bg-base-200/40 p-5"
      >
        <div class="mb-4 flex items-center gap-3">
          <span class="flex size-9 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name="hero-identification" class="size-5" />
          </span>
          <div>
            <h2 class="font-semibold">Account identity</h2>
            <p class="text-sm text-base-content/60">Profile and device status</p>
          </div>
        </div>

        <dl class="grid gap-3 text-sm sm:grid-cols-2">
          <div id="account-nickname" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Nickname</dt>
            <dd class="mt-1 font-medium">{@current_scope.user.display_name || "Not set"}</dd>
          </div>
          <div id="account-username" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Username</dt>
            <dd class="mt-1 font-medium">@{@current_scope.user.username}</dd>
          </div>
          <div id="account-role" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">Instance role</dt>
            <dd class="mt-1">
              <span class={[
                "badge badge-sm",
                if(@instance_admin, do: "badge-primary", else: "badge-neutral")
              ]}>
                {if @instance_admin, do: "Instance administrator", else: "Member"}
              </span>
            </dd>
          </div>
          <div id="account-identity-status" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">
              Identity (this browser)
            </dt>
            <dd class="mt-1">
              <span
                data-role="identity-status"
                class="badge badge-sm badge-neutral"
                aria-live="polite"
              >
                Checking…
              </span>
            </dd>
          </div>
          <div id="account-fcm-status" class="rounded-xl bg-base-100/70 px-3 py-2">
            <dt class="text-xs uppercase tracking-wide text-base-content/55">FCM notifications</dt>
            <dd class="mt-1">
              <span class={[
                "badge badge-sm",
                if(@fcm_device_count > 0, do: "badge-success", else: "badge-warning")
              ]}>
                {if @fcm_device_count > 0, do: "Registered", else: "Not registered"}
              </span>
              <span :if={@fcm_device_count > 0} class="ml-1 text-xs text-base-content/60">
                ({@fcm_device_count} device{if @fcm_device_count != 1, do: "s"})
              </span>
            </dd>
          </div>
        </dl>
      </section>

      <section class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3" aria-label="Account settings">
        <.link
          navigate={~p"/users/settings"}
          id="account-settings-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-cog-6-tooth" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <h2 class="mt-5 text-lg font-semibold">Settings</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Update your email, password, notifications, app installation, and account data.
          </p>
        </.link>

        <.link
          navigate={~p"/keys"}
          id="account-keys-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-secondary/10 text-secondary">
              <.icon name="hero-key" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <div class="mt-5 flex items-center gap-2">
            <h2 class="text-lg font-semibold">Encryption keys</h2>
            <span class={[
              "badge badge-sm",
              if(@current_scope.user.public_key, do: "badge-success", else: "badge-warning")
            ]}>
              {if @current_scope.user.public_key, do: "Configured", else: "Set up"}
            </span>
          </div>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Unlock, change, rotate, or reset the keys that protect your conversations.
          </p>
        </.link>

        <.link
          navigate={~p"/account/archives"}
          id="account-archives-link"
          class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <div class="flex items-start justify-between gap-4">
            <span class="flex size-11 items-center justify-center rounded-xl bg-base-200 text-base-content/70">
              <.icon name="hero-archive-box" class="size-6" />
            </span>
            <.icon
              name="hero-arrow-up-right"
              class="size-5 text-base-content/40 transition group-hover:text-primary"
            />
          </div>
          <h2 class="mt-5 text-lg font-semibold">Archived conversations</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            Review conversations you have tucked away and bring them back when needed.
          </p>
        </.link>
      </section>

      <section class="rounded-2xl border border-base-300/70 bg-base-200/40 p-5">
        <div class="flex items-center gap-3">
          <span class="flex size-9 items-center justify-center rounded-full bg-base-100 text-base-content/70">
            <.icon name="hero-at-symbol" class="size-5" />
          </span>
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-base-content/60">
              Signed in as
            </p>
            <p class="font-medium">{@current_scope.user.email}</p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     assign(socket,
       page_title: "Account",
       instance_admin: Veejr.Accounts.instance_admin?(user),
       fcm_device_count: Push.android_registration_count(user)
     )}
  end
end
