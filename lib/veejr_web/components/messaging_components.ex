defmodule VeejrWeb.MessagingComponents do
  @moduledoc """
  Shared UI for encrypted content: the composer form and envelope rendering.

  The composer is deliberately NOT a LiveView form — its inputs are read by
  the `Composer` JS hook, encrypted in the browser, and only ciphertext is
  pushed to the server.
  """
  use Phoenix.Component

  alias Veejr.Accounts.User
  alias Veejr.Messaging.Envelope

  attr :id, :string, required: true
  attr :user, User, required: true
  attr :friends, :list, required: true
  attr :groups, :list, required: true
  attr :kind, :string, default: "message"
  attr :payload, :string, default: nil, doc: "JSON merged into the payload (e.g. map coords)"
  attr :selected_friend_ids, :list, default: []
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
      class="rounded-lg border border-base-300 p-4 space-y-3"
    >
      <p data-role="error" class="hidden text-error text-sm"></p>

      <div :if={@friends == []} class="text-sm opacity-60">
        You have no friends to send to yet — add some on the Friends page.
      </div>

      <div :if={@friends != []}>
        <p class="text-sm font-medium mb-1">To friends:</p>
        <div class="flex flex-wrap gap-3">
          <label :for={friend <- @friends} class="label cursor-pointer gap-1 text-sm">
            <input
              type="checkbox"
              name="friends[]"
              value={friend.id}
              checked={to_string(friend.id) in @selected_friend_ids}
              class="checkbox checkbox-sm"
            />
            {friend.display_name || friend.username}
          </label>
        </div>
      </div>

      <div :if={@groups != []}>
        <p class="text-sm font-medium mb-1">To groups:</p>
        <div class="flex flex-wrap gap-3">
          <label :for={group <- @groups} class="label cursor-pointer gap-1 text-sm">
            <input type="checkbox" name="groups[]" value={group.id} class="checkbox checkbox-sm" />
            {group.name} ({length(group.members)})
          </label>
        </div>
      </div>

      <textarea
        :if={@show_text}
        data-role="text"
        rows="3"
        class="textarea w-full"
        placeholder={@text_placeholder}
      ></textarea>

      <input
        :if={@show_files}
        type="file"
        data-role="files"
        multiple
        class="file-input file-input-sm w-full"
      />

      <button type="submit" class="btn btn-primary" disabled={@friends == []}>
        🔐 {@submit_label}
      </button>
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
    <div class={["chat", (@mine && "chat-end") || "chat-start"]}>
      <div :if={!@mine} class="chat-header text-xs opacity-70 mb-0.5">
        {Veejr.Social.Address.handle(@envelope.sender)}
      </div>
      <div class={["chat-bubble max-w-[85%]", @mine && "chat-bubble-primary"]}>
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
      <div class="chat-footer text-xs opacity-50 mt-0.5">
        {Calendar.strftime(@envelope.inserted_at, "%H:%M")}
      </div>
    </div>
    """
  end
end
