defmodule VeejrWeb.UserLive.Archives do
  use VeejrWeb, :live_view

  alias Veejr.Messaging

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      container_class="mx-auto max-w-2xl space-y-8"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <.header>
          Archived conversations
          <:subtitle>
            Keep old conversations out of your Messages list without deleting them.
          </:subtitle>
        </.header>
        <.link navigate={~p"/account"} class="btn btn-ghost btn-sm">Back to account</.link>
      </div>

      <section aria-label="Archived conversations" class="space-y-3">
        <p
          :if={@archives == []}
          class="rounded-2xl border border-dashed border-base-300 p-8 text-center text-sm opacity-70"
        >
          No archived conversations.
        </p>

        <article
          :for={archive <- @archives}
          id={"archive-#{archive.key}"}
          class="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
        >
          <div class="flex min-w-0 items-center gap-3">
            <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content/70">
              <.icon name="hero-archive-box" class="size-5" />
            </span>
            <div class="min-w-0">
              <h2 class="truncate font-medium">{Enum.join(archive.participants, ", ")}</h2>
              <p class="text-xs opacity-60">
                Started {Calendar.strftime(archive.started_at, "%b %d, %Y")} · Archived {Calendar.strftime(
                  archive.archived_at,
                  "%b %d, %Y"
                )}
              </p>
            </div>
          </div>
          <button
            id={"unarchive-#{archive.key}"}
            type="button"
            phx-click="unarchive"
            phx-value-key={archive.key}
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Unarchive
          </button>
        </article>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Archived conversations") |> refresh()}
  end

  @impl true
  def handle_event("unarchive", %{"key" => key}, socket) do
    case Messaging.unarchive_conversation(socket.assigns.current_scope.user, key) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation unarchived.")
         |> push_navigate(to: ~p"/messages?conversation=#{key}")}

      {:error, :not_archived} ->
        {:noreply, put_flash(socket, :error, "That conversation is already unarchived.")}
    end
  end

  defp refresh(socket) do
    assign(socket,
      archives: Messaging.list_archived_conversations(socket.assigns.current_scope.user)
    )
  end
end
