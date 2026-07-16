defmodule VeejrWeb.InvitationLive.New do
  use VeejrWeb, :live_view

  alias Veejr.Accounts
  alias Veejr.Social.Address

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-6"
    >
      <.header>
        Invite someone
        <:subtitle>
          Ask them to scan this code. The invitation can be used once and expires in seven days.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Contacts
          </.link>
        </:actions>
      </.header>

      <section class="grid items-center gap-6 rounded-lg border border-base-300 bg-base-100 p-5 sm:grid-cols-[minmax(0,1fr)_16rem]">
        <div>
          <p class="text-sm font-semibold uppercase opacity-60">Invitation from</p>
          <p class="mt-1 text-xl font-semibold">
            {@current_scope.user.display_name || Address.handle(@current_scope.user)}
          </p>
          <p class="text-sm opacity-70">{Address.handle(@current_scope.user)}</p>

          <p class="mt-5 text-sm font-semibold uppercase opacity-60">Joining</p>
          <p class="mt-1 font-medium">{Veejr.instance_name()}</p>

          <label for="invite-url" class="mt-5 block text-sm font-medium">Invitation link</label>
          <input
            id="invite-url"
            type="text"
            value={@invite_url}
            readonly
            class="input mt-1 w-full font-mono text-xs"
          />
        </div>

        <div class="mx-auto aspect-square w-full max-w-64 rounded-lg border border-base-300 bg-white p-3">
          <img
            src={"data:image/svg+xml;base64,#{@qr_code}"}
            alt="QR code for this invitation"
            class="size-full"
          />
        </div>
      </section>

      <div class="flex justify-end">
        <button phx-click="new_invitation" class="btn btn-outline btn-sm">
          <.icon name="hero-arrow-path" class="size-4" /> Create another code
        </button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Invite someone") |> assign_invitation()}
  end

  @impl true
  def handle_event("new_invitation", _params, socket) do
    {:noreply, assign_invitation(socket)}
  end

  defp assign_invitation(socket) do
    {:ok, _invitation, token} = Accounts.create_invitation(socket.assigns.current_scope.user)
    invite_url = url(~p"/users/register?invite=#{token}")

    {:ok, qr_code} =
      invite_url
      |> QRCode.create(:medium)
      |> QRCode.render(:svg)
      |> QRCode.to_base64()

    assign(socket, invite_url: invite_url, qr_code: qr_code)
  end
end
