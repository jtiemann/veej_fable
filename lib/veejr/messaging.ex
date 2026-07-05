defmodule Veejr.Messaging do
  @moduledoc """
  Encrypted envelopes, pull-based notifications, and attachment blobs.

  The server's role is deliberately dumb: it stores ciphertext produced in the
  sender's browser and hands it out only after the recipient explicitly
  accepts the notification ("no data is sent unless the receiver has
  requested it"). Plaintext never exists server-side.
  """

  import Ecto.Query, warn: false

  alias Veejr.Repo
  alias Veejr.Accounts.User
  alias Veejr.Messaging.{Envelope, Notification, Blob}
  alias Veejr.Social

  ## PubSub

  def subscribe(%User{id: id}), do: Phoenix.PubSub.subscribe(Veejr.PubSub, topic(id))

  defp topic(user_id), do: "user:#{user_id}"

  defp broadcast_notification(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      topic(notification.user_id),
      {:veejr_notification, notification}
    )
  end

  ## Sending

  @doc """
  Stores a batch of envelopes — one per recipient, each encrypted client-side
  to that recipient's key — and notifies every recipient other than the
  sender. The sender's self-copy keeps their history readable.

  Every recipient must be the sender or an accepted friend of the sender.
  """
  def send_batch(%User{} = sender, kind, envelopes) when is_list(envelopes) do
    batch_id = random_id()

    result =
      Repo.transaction(fn ->
        for attrs <- envelopes do
          recipient_id = parse_id(attrs["recipient_id"] || attrs[:recipient_id])

          unless recipient_id == sender.id or Social.friends?(sender.id, recipient_id) do
            Repo.rollback({:not_a_friend, recipient_id})
          end

          envelope =
            %Envelope{sender_id: sender.id, public_id: random_id(), batch_id: batch_id}
            |> Envelope.changeset(%{
              recipient_id: recipient_id,
              kind: kind,
              ciphertext: attrs["ciphertext"] || attrs[:ciphertext],
              nonce: attrs["nonce"] || attrs[:nonce]
            })
            |> case do
              %{valid?: true} = changeset -> Repo.insert!(changeset)
              changeset -> Repo.rollback(changeset)
            end

          if recipient_id == sender.id do
            {envelope, nil}
          else
            notification =
              Repo.insert!(%Notification{envelope_id: envelope.id, user_id: recipient_id})

            {envelope, notification}
          end
        end
      end)

    with {:ok, pairs} <- result do
      for {_envelope, %Notification{} = notification} <- pairs do
        broadcast_notification(Repo.preload(notification, envelope: [:sender]))
      end

      {:ok, batch_id}
    end
  end

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)

  ## Notifications (the pull side)

  @doc "Pending notifications for `user`, newest first, sender preloaded."
  def list_pending_notifications(%User{id: id}) do
    from(n in Notification,
      where: n.user_id == ^id and n.state == "pending",
      preload: [envelope: [:sender]],
      order_by: [desc: n.id]
    )
    |> Repo.all()
  end

  def count_pending_notifications(%User{id: id}) do
    from(n in Notification, where: n.user_id == ^id and n.state == "pending")
    |> Repo.aggregate(:count)
  end

  @doc """
  The recipient requests the data: only after this does the server serve the
  ciphertext to them.
  """
  def accept_notification(%User{} = user, id), do: set_notification_state(user, id, "accepted")

  @doc "The recipient declines; the ciphertext is never served to them."
  def decline_notification(%User{} = user, id), do: set_notification_state(user, id, "declined")

  defp set_notification_state(%User{id: user_id}, id, state) do
    case Repo.get_by(Notification, id: id, user_id: user_id, state: "pending") do
      nil ->
        {:error, :not_found}

      notification ->
        notification
        |> Ecto.Changeset.change(state: state)
        |> Repo.update()
    end
  end

  ## Reading envelopes

  @doc """
  Fetches an envelope's ciphertext for `user`.

  Authorized when the user is the sender (their own copies) or an accepted
  recipient. Marks first delivery.
  """
  def fetch_envelope(%User{id: user_id}, public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id,
        left_join: n in assoc(e, :notification),
        preload: [:sender, :recipient, notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      envelope.recipient_id == user_id and envelope.sender_id == user_id ->
        {:ok, envelope}

      envelope.recipient_id == user_id and accepted?(envelope.notification) ->
        {:ok, mark_delivered(envelope)}

      true ->
        {:error, :unauthorized}
    end
  end

  defp accepted?(%Notification{state: "accepted"}), do: true
  defp accepted?(_), do: false

  defp mark_delivered(%Envelope{delivered_at: nil} = envelope) do
    {:ok, envelope} =
      envelope
      |> Ecto.Changeset.change(delivered_at: DateTime.utc_now(:second))
      |> Repo.update()

    envelope
  end

  defp mark_delivered(envelope), do: envelope

  ## History

  @doc """
  Everything `user` can decrypt, newest first: their own self-copies (sent
  items) and received envelopes they accepted. Filterable by `:kind`.
  """
  def list_history(%User{id: id}, opts \\ []) do
    query =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and
            (e.sender_id == ^id or n.state == "accepted"),
        preload: [:sender],
        order_by: [desc: e.id]
      )

    query =
      case opts[:kind] do
        nil -> query
        kind -> where(query, [e], e.kind == ^kind)
      end

    query =
      case opts[:limit] do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc """
  For a batch the user sent: who else received it (usernames), so the sent
  view can say "to alice, bob".
  """
  def batch_recipients(%User{id: id}, batch_id) do
    from(e in Envelope,
      join: u in assoc(e, :recipient),
      where: e.batch_id == ^batch_id and e.sender_id == ^id and e.recipient_id != ^id,
      select: u.username,
      order_by: u.username
    )
    |> Repo.all()
  end

  ## Blobs (encrypted attachments)

  @max_blob_size 25 * 1024 * 1024

  def max_blob_size, do: @max_blob_size

  @doc """
  Stores an already-encrypted attachment body and returns the blob. The
  content is opaque to the server; the decryption key travels inside the
  message envelope.
  """
  def create_blob(%User{} = owner, binary) when is_binary(binary) do
    if byte_size(binary) > @max_blob_size do
      {:error, :too_large}
    else
      public_id = random_id()
      dir = blob_dir()
      File.mkdir_p!(dir)
      path = Path.join(dir, public_id <> ".bin")
      File.write!(path, binary)

      Repo.insert(%Blob{
        public_id: public_id,
        owner_id: owner.id,
        size: byte_size(binary),
        path: path
      })
    end
  end

  @doc """
  Looks up a blob by its unguessable id. Possession of the id is the
  capability: the id only ever travels inside encrypted envelopes, and the
  content is itself ciphertext.
  """
  def get_blob(public_id) do
    Repo.get_by(Blob, public_id: public_id)
  end

  @doc """
  Removes a user's blob files from disk (rows go with the user via FK
  cascade, files don't).
  """
  def purge_blob_files(%User{id: id}) do
    for blob <- Repo.all(from(b in Blob, where: b.owner_id == ^id)) do
      File.rm(blob.path)
    end

    :ok
  end

  def blob_dir do
    Application.get_env(
      :veejr,
      :blob_dir,
      Path.join(Application.app_dir(:veejr, "priv"), "uploads")
    )
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
