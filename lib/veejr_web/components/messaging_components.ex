defmodule VeejrWeb.MessagingComponents do
  @moduledoc """
  Shared UI for encrypted content: the composer form and envelope rendering.

  The composer is deliberately NOT a LiveView form — its inputs are read by
  the `Composer` JS hook, encrypted in the browser, and only ciphertext is
  pushed to the server.
  """
  use Phoenix.Component
  import VeejrWeb.CoreComponents, only: [icon: 1]

  alias Veejr.Accounts.User
  alias Veejr.Messaging.Envelope

  attr :id, :string, required: true
  attr :user, User, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :kind, :string, default: "message"
  attr :payload, :string, default: nil, doc: "JSON merged into the payload (e.g. map coords)"
  attr :selected_friend_ids, :list, default: []
  attr :surface, :string, default: "card"
  attr :show_text, :boolean, default: true
  attr :show_files, :boolean, default: true

  attr :text_placeholder, :string,
    default: "Write something… it is encrypted before it leaves this browser."

  attr :submit_label, :string, default: "Encrypt & send"

  def composer(assigns) do
    ~H"""
    <form
      id={@id}
      phx-hook="Composer"
      data-user-id={@user.id}
      data-my-key={@user.public_key}
      data-kind={@kind}
      data-payload={@payload}
      class={[
        "space-y-3",
        @surface == "messages" &&
          "rounded-[28px] border border-slate-200 bg-white p-3 shadow-sm",
        @surface != "messages" &&
          "rounded-lg border border-base-300 p-4"
      ]}
    >
      <p data-role="error" class="hidden text-error text-sm"></p>

      <div :if={@friends == []} class="px-2 text-sm text-slate-500">
        You have no friends to send to yet — add some on the Friends page.
      </div>

      <div :if={@friends != []}>
        <p class="mb-2 px-2 text-xs font-medium uppercase tracking-wide text-slate-500">
          Friends
        </p>
        <div class="flex flex-wrap gap-2">
          <label
            :for={friend <- @friends}
            class={[
              "flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1.5 text-sm transition",
              to_string(friend.id) in @selected_friend_ids &&
                "border-blue-200 bg-blue-50 text-blue-800",
              to_string(friend.id) not in @selected_friend_ids &&
                "border-slate-200 bg-slate-50 text-slate-700 hover:bg-slate-100"
            ]}
          >
            <input
              type="checkbox"
              name="friends[]"
              value={friend.id}
              checked={to_string(friend.id) in @selected_friend_ids}
              class="checkbox checkbox-xs border-slate-300"
            />
            {friend.display_name || friend.username}
          </label>
        </div>
      </div>

      <div :if={@groups != []}>
        <p class="mb-2 px-2 text-xs font-medium uppercase tracking-wide text-slate-500">
          Groups
        </p>
        <div class="flex flex-wrap gap-2">
          <label
            :for={group <- @groups}
            class="flex cursor-pointer items-center gap-2 rounded-full border border-slate-200 bg-slate-50 px-3 py-1.5 text-sm text-slate-700 transition hover:bg-slate-100"
          >
            <input
              type="checkbox"
              name="groups[]"
              value={group.id}
              class="checkbox checkbox-xs border-slate-300"
            />
            {group.name} ({length(group.members)})
          </label>
        </div>
      </div>

      <div class={[
        @surface == "messages" && "flex items-end gap-2",
        @surface != "messages" && "space-y-3"
      ]}>
        <textarea
          :if={@show_text}
          data-role="text"
          rows={if(@surface == "messages", do: "1", else: "3")}
          class={[
            "textarea w-full resize-none",
            @surface == "messages" &&
              "min-h-11 rounded-[22px] border-0 bg-slate-100 px-4 py-3 text-slate-900 placeholder:text-slate-500 focus:outline-none focus:ring-2 focus:ring-blue-200",
            @surface != "messages" && "textarea-bordered"
          ]}
          placeholder={@text_placeholder}
        ></textarea>

        <label
          :if={@show_files && @surface == "messages"}
          title="Attach files"
          class="flex size-11 shrink-0 cursor-pointer items-center justify-center rounded-full bg-slate-100 text-slate-500 transition hover:bg-slate-200 hover:text-slate-700"
        >
          <.icon name="hero-paper-clip" class="size-5" />
          <span class="sr-only">Attach files</span>
          <input type="file" data-role="files" multiple class="sr-only" />
        </label>

        <input
          :if={@show_files && @surface != "messages"}
          type="file"
          data-role="files"
          multiple
          class="file-input file-input-sm w-full"
        />

        <button
          type="submit"
          class={[
            "btn border-0",
            @surface == "messages" &&
              "h-11 min-h-11 rounded-full bg-blue-600 px-5 text-white shadow-none hover:bg-blue-700",
            @surface != "messages" && "btn-primary"
          ]}
          disabled={@friends == []}
        >
          {@submit_label}
        </button>
      </div>
    </form>
    """
  end

  attr :envelope, Envelope, required: true, doc: "sender preloaded"
  attr :user, User, required: true
  attr :label, :string, required: true

  def envelope_item(assigns) do
    ~H"""
    <li class="rounded-lg border border-base-300 p-3">
      <div class="flex items-center justify-between text-sm opacity-70">
        <span>{kind_icon(@envelope.kind)} {@label}</span>
        <span>{Calendar.strftime(@envelope.inserted_at, "%b %d, %H:%M")} UTC</span>
      </div>
      <div
        id={"env-#{@envelope.public_id}"}
        phx-hook="Decrypt"
        phx-update="ignore"
        data-user-id={@user.id}
        data-peer-key={Veejr.Messaging.peer_key(@envelope, @user)}
        data-ciphertext={@envelope.ciphertext}
        data-nonce={@envelope.nonce}
        data-kind={@envelope.kind}
        class="mt-2"
      >
        <span class="loading loading-dots loading-xs"></span>
      </div>
    </li>
    """
  end

  def kind_icon("message"), do: "✉️"
  def kind_icon("location"), do: "📍"
  def kind_icon("note"), do: "📝"
  def kind_icon(_), do: "✉️"

  @doc """
  A single message rendered as a chat bubble: your own messages align right
  in the accent color, others align left with the sender's handle. The bubble
  body is filled in by the `Decrypt` hook — plaintext never reaches the server.
  """
  attr :envelope, Envelope, required: true, doc: "sender preloaded"
  attr :user, User, required: true
  attr :mine, :boolean, required: true

  def message_bubble(assigns) do
    ~H"""
    <div class={["flex flex-col", @mine && "items-end", !@mine && "items-start"]}>
      <div :if={!@mine} class="mb-1 ml-3 text-xs font-medium text-slate-500">
        {Veejr.Social.Address.handle(@envelope.sender)}
      </div>
      <div class={[
        "max-w-[78%] rounded-[22px] px-4 py-2 text-[0.95rem] leading-relaxed shadow-sm",
        @mine && "rounded-br-md bg-blue-600 text-white",
        !@mine && "rounded-bl-md bg-white text-slate-900 ring-1 ring-slate-200"
      ]}>
        <div
          id={"env-#{@envelope.public_id}"}
          phx-hook="Decrypt"
          phx-update="ignore"
          data-user-id={@user.id}
          data-peer-key={Veejr.Messaging.peer_key(@envelope, @user)}
          data-ciphertext={@envelope.ciphertext}
          data-nonce={@envelope.nonce}
          data-kind={@envelope.kind}
        >
          <span class="loading loading-dots loading-xs"></span>
        </div>
      </div>
      <div class={["mt-1 text-xs text-slate-400", @mine && "mr-3", !@mine && "ml-3"]}>
        <span>{Calendar.strftime(@envelope.inserted_at, "%H:%M")}</span>
        <button
          type="button"
          phx-click="delete_envelope"
          phx-value-id={@envelope.public_id}
          data-confirm={delete_confirm(@mine)}
          class="ml-2 rounded-full px-1.5 py-0.5 text-slate-400 hover:bg-slate-200 hover:text-slate-700"
        >
          {delete_label(@mine)}
        </button>
      </div>
    </div>
    """
  end

  defp delete_label(true), do: "delete"
  defp delete_label(false), do: "hide"

  defp delete_confirm(true),
    do: "Delete this sent item for every recipient? This cannot be undone."

  defp delete_confirm(false),
    do: "Hide this item from your history? You can request a future message again."
end
