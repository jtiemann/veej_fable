defmodule VeejrWeb.GuestConferenceLive.New do
  use VeejrWeb, :live_view

  alias Veejr.Accounts.UserNotifier
  alias Veejr.GuestConferences

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-xl space-y-6"
    >
      <.header>
        Invite a guest call
        <:subtitle>
          Your guest can join this private 1:1 video call without creating an account.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Contacts
          </.link>
        </:actions>
      </.header>

      <section class="overflow-hidden rounded-3xl border border-base-300 bg-base-100 shadow-sm">
        <div class="border-b border-base-300 bg-primary/5 px-6 py-5">
          <div class="flex items-start gap-3">
            <span class="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-video-camera" class="size-6" />
            </span>
            <div>
              <h2 class="font-semibold">Immediate conference</h2>
              <p class="mt-1 text-sm leading-relaxed opacity-65">
                The link expires in two hours. You will admit the guest from a waiting room
                before anything connects.
              </p>
            </div>
          </div>
        </div>

        <.form
          for={@form}
          id="guest-conference-invite-form"
          phx-change="validate"
          phx-submit="send"
          class="space-y-5 p-6"
        >
          <.input
            field={@form[:invited_email]}
            type="email"
            label="Guest email"
            placeholder="guest@example.com"
            autocomplete="email"
            spellcheck="false"
            required
          />

          <p class="rounded-2xl bg-base-200 px-4 py-3 text-sm leading-relaxed opacity-75">
            The guest will only be able to access this conference. They will not see your
            contacts, messages, or history.
          </p>

          <.button
            id="send-guest-conference-invite"
            phx-disable-with="Sending invitation..."
            class="btn btn-primary w-full rounded-xl"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> Send invitation
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Invite a guest call")
     |> assign_form(GuestConferences.change_invitation())}
  end

  @impl true
  def handle_event("validate", %{"guest_conference" => attrs}, socket) do
    changeset =
      attrs
      |> GuestConferences.change_invitation()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("send", %{"guest_conference" => attrs}, socket) do
    host = socket.assigns.current_scope.user

    case GuestConferences.create_invitation(host, attrs) do
      {:ok, conference, token} ->
        invite_url = url(~p"/guest/#{token}")

        case UserNotifier.deliver_guest_conference_invitation(
               host,
               conference.invited_email,
               invite_url
             ) do
          {:ok, _email} ->
            {:noreply,
             socket
             |> put_flash(:info, "The private conference invitation was sent.")
             |> push_navigate(to: ~p"/guest-conferences/#{conference.public_id}")}

          {:error, _reason} ->
            GuestConferences.revoke(host, conference)

            {:noreply,
             socket
             |> put_flash(:error, "The invitation email could not be delivered.")
             |> assign_form(GuestConferences.change_invitation(attrs))}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: :guest_conference))
  end
end
