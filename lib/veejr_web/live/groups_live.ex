defmodule VeejrWeb.GroupsLive do
  use VeejrWeb, :live_view

  alias Veejr.Social

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_count={@pending_count}>
      <.header>
        Groups
        <:subtitle>
          Organize your friends into groups — share messages or your location with a
          whole group at once. A friend can be in any number of groups.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/friends"} class="btn btn-ghost btn-sm">Back to friends</.link>
        </:actions>
      </.header>

      <form phx-submit="create_group" class="mt-6 flex gap-2">
        <input
          type="text"
          name="name"
          placeholder="new group name"
          class="input flex-1"
          autocomplete="off"
          required
        />
        <button type="submit" class="btn btn-primary">Create group</button>
      </form>

      <p :if={@groups == []} class="mt-6 text-sm opacity-60">
        No groups yet. Try “family”, “hiking crew”, “work”…
      </p>

      <div class="mt-6 space-y-6">
        <section :for={group <- @groups} class="rounded-lg border border-base-300 p-4">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold">{group.name}</h2>
            <button
              phx-click="delete_group"
              phx-value-id={group.id}
              data-confirm={"Delete group “#{group.name}”? Friends stay friends."}
              class="btn btn-ghost btn-sm"
            >
              Delete
            </button>
          </div>

          <div class="mt-3 flex flex-wrap gap-2">
            <span :for={member <- group.members} class="badge badge-outline gap-1">
              {member.display_name || member.username}
              <button
                phx-click="remove_member"
                phx-value-group={group.id}
                phx-value-user={member.id}
                class="ml-1 opacity-60 hover:opacity-100"
                aria-label="remove from group"
              >
                ✕
              </button>
            </span>
            <span :if={group.members == []} class="text-sm opacity-60">No members yet.</span>
          </div>

          <form
            :if={addable_friends(@friends, group) != []}
            phx-submit="add_member"
            class="mt-3 flex gap-2"
          >
            <input type="hidden" name="group" value={group.id} />
            <select name="user" class="select select-sm flex-1">
              <option :for={friend <- addable_friends(@friends, group)} value={friend.id}>
                {friend.display_name || friend.username} (@{friend.username})
              </option>
            </select>
            <button type="submit" class="btn btn-sm">Add</button>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp addable_friends(friends, group) do
    member_ids = MapSet.new(group.members, & &1.id)
    Enum.reject(friends, &MapSet.member?(member_ids, &1.id))
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Groups") |> refresh()}
  end

  @impl true
  def handle_event("create_group", %{"name" => name}, socket) do
    socket =
      case Social.create_group(socket.assigns.current_scope.user, %{name: String.trim(name)}) do
        {:ok, group} -> put_flash(socket, :info, "Group “#{group.name}” created.")
        {:error, changeset} -> put_flash(socket, :error, error_from(changeset))
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    Social.delete_group(socket.assigns.current_scope.user, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("add_member", %{"group" => group_id, "user" => user_id}, socket) do
    case Social.add_group_member(
           socket.assigns.current_scope.user,
           group_id,
           String.to_integer(user_id)
         ) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :not_a_friend} ->
        {:noreply, put_flash(socket, :error, "Only friends can join your groups.")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not add member.") |> refresh()}
    end
  end

  def handle_event("remove_member", %{"group" => group_id, "user" => user_id}, socket) do
    Social.remove_group_member(
      socket.assigns.current_scope.user,
      group_id,
      String.to_integer(user_id)
    )

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    user = socket.assigns.current_scope.user
    assign(socket, groups: Social.list_groups(user), friends: Social.list_friends(user))
  end

  defp error_from(%Ecto.Changeset{errors: [{_field, {msg, _}} | _]}), do: msg
  defp error_from(_), do: "Something went wrong."
end
