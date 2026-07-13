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

  alias Veejr.Messaging.{
    Blob,
    ConversationWindow,
    Envelope,
    MessageDeliveryPolicy,
    Notification
  }

  alias Veejr.Social

  # How long an active conversation keeps auto-accepting new messages without
  # a fresh request. Re-upped on every send or receive.
  @window_seconds 5 * 60
  @max_expiry_seconds 60 * 60 * 24 * 30

  ## PubSub

  def subscribe(%User{id: id}), do: Phoenix.PubSub.subscribe(Veejr.PubSub, topic(id))

  defp topic(user_id), do: "user:#{user_id}"

  defp broadcast_notification(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(
      Veejr.PubSub,
      topic(notification.user_id),
      {:veejr_notification, notification}
    )

    envelope = notification.envelope

    should_push? =
      notification.state == "pending" or
        (notification.state == "accepted" and
           automatic_delivery?(notification.user, envelope.sender) and
           delivery_notification_mode(notification.user, envelope.sender) != "silent")

    if should_push?, do: Veejr.Push.notify_async(notification)
    :ok
  end

  ## Active-conversation windows

  @doc """
  Is `peer`'s conversation with `user` currently active — i.e. should a new
  message from `peer` be auto-accepted for `user` rather than held as a
  request?
  """
  def conversation_active?(user_id, peer_id) do
    now = DateTime.utc_now(:second)

    case Repo.get_by(ConversationWindow, user_id: user_id, peer_id: peer_id) do
      %ConversationWindow{active_until: until} -> DateTime.compare(until, now) == :gt
      nil -> false
    end
  end

  @doc """
  Re-ups `user`'s auto-accept window for `peer` to #{@window_seconds} seconds
  from now. Called on every send to, and accepted receive from, `peer`.
  """
  def touch_conversation(user_id, peer_id) do
    now = DateTime.utc_now(:second)
    until = DateTime.add(now, @window_seconds, :second)

    Repo.insert!(
      %ConversationWindow{
        user_id: user_id,
        peer_id: peer_id,
        active_until: until,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [active_until: until, updated_at: now]],
      conflict_target: [:user_id, :peer_id]
    )

    :ok
  end

  ## Sending

  @doc """
  Stores a batch of envelopes — one per recipient, each encrypted client-side
  to that recipient's key — and notifies every recipient other than the
  sender. The sender's self-copy keeps their history readable.

  Every recipient must be the sender or an accepted friend of the sender.
  """
  def send_batch(%User{} = sender, kind, envelopes, opts \\ []) when is_list(envelopes) do
    batch_id = random_id()
    expires_at = normalize_expires_at(opt(opts, :expires_at))
    max_displays = normalize_max_displays(opt(opts, :max_displays))

    result =
      Repo.transaction(fn ->
        for attrs <- envelopes do
          recipient_id =
            case parse_id(attrs["recipient_id"] || attrs[:recipient_id]) do
              {:ok, id} -> id
              :error -> Repo.rollback(:bad_recipient_id)
            end

          recipient = Repo.get(User, recipient_id) || Repo.rollback({:no_such_user, recipient_id})

          unless recipient.id == sender.id or Social.friends?(sender.id, recipient.id) do
            Repo.rollback({:not_a_friend, recipient.id})
          end

          envelope =
            %Envelope{
              sender_id: sender.id,
              public_id: random_id(),
              batch_id: batch_id,
              sender_public_key: sender.public_key
            }
            |> Envelope.changeset(%{
              recipient_id: recipient.id,
              kind: kind,
              ciphertext: attrs["ciphertext"] || attrs[:ciphertext],
              nonce: attrs["nonce"] || attrs[:nonce],
              expires_at: expires_at,
              max_displays: max_displays
            })
            |> case do
              %{valid?: true} = changeset -> Repo.insert!(changeset)
              changeset -> Repo.rollback(changeset)
            end

          cond do
            recipient.id == sender.id ->
              {envelope, nil}

            # Local recipient: notify in-place. If their conversation with the
            # sender is active, the message is auto-accepted and just shows up.
            is_nil(recipient.host) ->
              # sending re-ups the sender's own window for this recipient
              touch_conversation(sender.id, recipient.id)

              state =
                if conversation_active?(recipient.id, sender.id) or
                     automatic_delivery?(recipient, sender) do
                  touch_conversation(recipient.id, sender.id)
                  "accepted"
                else
                  "pending"
                end

              notification =
                Repo.insert!(%Notification{
                  envelope_id: envelope.id,
                  user_id: recipient.id,
                  state: state
                })

              {envelope, notification}

            # Remote recipient: the envelope stays here; their instance gets a
            # content-free notify after commit. The auto-accept decision happens
            # on their instance in receive_remote_notify/4.
            true ->
              touch_conversation(sender.id, recipient.id)
              {envelope, {:remote, recipient}}
          end
        end
      end)

    with {:ok, pairs} <- result do
      for {_envelope, %Notification{} = notification} <- pairs do
        broadcast_notification(Repo.preload(notification, [:user, envelope: [:sender]]))
      end

      queued =
        for {envelope, {:remote, recipient}} <- pairs,
            envelope = Repo.preload(envelope, :sender),
            {:queued, _} <- [Veejr.Federation.deliver_notify(envelope, recipient)] do
          Veejr.Social.Address.handle(recipient)
        end

      {:ok, batch_id, queued}
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  def list_batch_copies(%User{id: sender_id}, batch_id) do
    from(e in Envelope,
      where: e.sender_id == ^sender_id and e.batch_id == ^batch_id,
      select: %{recipient_id: e.recipient_id, public_id: e.public_id}
    )
    |> Repo.all()
  end

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp opt(opts, key) when is_map(opts),
    do: Map.get(opts, Atom.to_string(key)) || Map.get(opts, key)

  defp opt(_opts, _key), do: nil

  defp normalize_expires_at(nil), do: nil
  defp normalize_expires_at(""), do: nil

  defp normalize_expires_at(value) when is_binary(value) do
    with {:ok, datetime, _} <- DateTime.from_iso8601(value) do
      normalize_expires_at(datetime)
    else
      _ -> nil
    end
  end

  defp normalize_expires_at(%DateTime{} = datetime) do
    now = DateTime.utc_now(:second)
    latest = DateTime.add(now, @max_expiry_seconds, :second)
    datetime = DateTime.truncate(datetime, :second)

    cond do
      DateTime.compare(datetime, now) != :gt -> nil
      DateTime.compare(datetime, latest) == :gt -> latest
      true -> datetime
    end
  end

  defp normalize_expires_at(_), do: nil

  defp normalize_max_displays(nil), do: nil
  defp normalize_max_displays(""), do: nil
  defp normalize_max_displays(count) when is_integer(count) and count > 0, do: min(count, 100)

  defp normalize_max_displays(count) when is_binary(count) do
    case Integer.parse(count) do
      {int, ""} when int > 0 -> normalize_max_displays(int)
      _ -> nil
    end
  end

  defp normalize_max_displays(_), do: nil

  ## Notifications (the pull side)

  @doc "Pending notifications for `user`, newest first, sender preloaded."
  def list_pending_notifications(%User{id: id}) do
    now = DateTime.utc_now(:second)

    from(n in Notification,
      join: e in assoc(n, :envelope),
      where:
        n.user_id == ^id and n.state == "pending" and
          (is_nil(e.expires_at) or e.expires_at > ^now) and
          (is_nil(e.max_displays) or e.display_count < e.max_displays),
      preload: [envelope: [:sender]],
      order_by: [desc: n.id]
    )
    |> Repo.all()
  end

  def count_pending_notifications(%User{id: id}) do
    now = DateTime.utc_now(:second)

    from(n in Notification,
      join: e in assoc(n, :envelope),
      where:
        n.user_id == ^id and n.state == "pending" and
          (is_nil(e.expires_at) or e.expires_at > ^now) and
          (is_nil(e.max_displays) or e.display_count < e.max_displays)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  The recipient requests the data: only after this does the ciphertext move.

  For envelopes that originated on another instance, this is the moment the
  content is fetched from the origin server. If the origin is unreachable the
  notification stays pending so the user can retry.
  """
  def accept_notification(%User{} = user, id) do
    case Repo.get_by(Notification, id: id, user_id: user.id, state: "pending") do
      nil ->
        {:error, :not_found}

      notification ->
        envelope = Repo.preload(notification, envelope: [:sender]).envelope

        with false <- expired?(envelope),
             :ok <- maybe_fetch_remote_content(envelope) do
          # accepting opens/extends the active-conversation window
          touch_conversation(user.id, envelope.sender_id)

          case notification |> Ecto.Changeset.change(state: "accepted") |> Repo.update() do
            {:ok, updated} -> {:ok, Repo.preload(updated, [envelope: [:sender]], force: true)}
            error -> error
          end
        else
          true -> {:error, :not_found}
          error -> error
        end
    end
  end

  # Local envelopes already hold their ciphertext; remote stubs are empty
  # until the recipient asks.
  defp maybe_fetch_remote_content(%Envelope{ciphertext: ""} = envelope) do
    case Veejr.Federation.fetch_envelope_content(envelope) do
      {:ok, ciphertext, nonce} ->
        {:ok, _} =
          envelope
          |> Ecto.Changeset.change(ciphertext: ciphertext, nonce: nonce)
          |> Repo.update()

        :ok

      {:error, _reason} ->
        {:error, :origin_unreachable}
    end
  end

  defp maybe_fetch_remote_content(_envelope), do: :ok

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

  ## Federation

  @doc """
  Records an incoming cross-instance announcement as a content-free stub
  envelope plus a pending notification. The ciphertext stays on the origin
  instance until the recipient accepts.
  """
  def receive_remote_notify(%User{} = remote_sender, %User{} = local_recipient, kind, public_id) do
    cond do
      kind not in Envelope.kinds() ->
        {:error, :bad_request}

      Repo.get_by(Envelope, public_id: public_id) ->
        # replay or duplicate delivery — already recorded
        {:ok, :duplicate}

      true ->
        envelope =
          Repo.insert!(%Envelope{
            public_id: public_id,
            batch_id: public_id,
            sender_id: remote_sender.id,
            recipient_id: local_recipient.id,
            kind: kind,
            ciphertext: "",
            nonce: "",
            sender_public_key: remote_sender.public_key
          })

        # Active conversation: fetch the ciphertext now and auto-accept so it
        # lands straight in the chat. If the fetch fails, fall back to a
        # pending request the recipient can retry.
        state =
          if (conversation_active?(local_recipient.id, remote_sender.id) or
                automatic_delivery?(local_recipient, remote_sender)) and
               maybe_fetch_remote_content(Repo.preload(envelope, :sender)) == :ok do
            touch_conversation(local_recipient.id, remote_sender.id)
            "accepted"
          else
            "pending"
          end

        notification =
          Repo.insert!(%Notification{
            envelope_id: envelope.id,
            user_id: local_recipient.id,
            state: state
          })

        broadcast_notification(Repo.preload(notification, [:user, envelope: [:sender]]))
        {:ok, :created}
    end
  end

  @doc """
  Serves an envelope over the federation capability endpoint. Only envelopes
  addressed to remote recipients are ever served this way — local users read
  through their authenticated session. Possession of the unguessable
  public_id (delivered only to the recipient's instance) is the capability.
  """
  def get_public_envelope(public_id) do
    envelope =
      from(e in Envelope,
        join: r in assoc(e, :recipient),
        where: e.public_id == ^public_id and not is_nil(r.host)
      )
      |> Repo.one()

    cond do
      is_nil(envelope) -> {:error, :not_found}
      expired?(envelope) -> {:error, :not_found}
      true -> {:ok, mark_delivered(envelope)}
    end
  end

  @doc """
  The public key an envelope's ciphertext must be opened against, for `user`
  as the reader. Resealed envelopes use the reader's own current key; all
  others use the sender-key snapshot taken at send time, so history stays
  readable across key rotations.
  """
  def peer_key(%Envelope{resealed: true}, %User{} = user), do: user.public_key

  def peer_key(%Envelope{sender_id: uid, sender_public_key: snapshot}, %User{id: uid} = user),
    do: snapshot || user.public_key

  def peer_key(%Envelope{sender_public_key: snapshot} = envelope, _user),
    do: snapshot || envelope.sender.public_key

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

      expired?(envelope) ->
        {:error, :not_found}

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
    now = DateTime.utc_now(:second)

    query =
      from(e in Envelope,
        left_join: n in assoc(e, :notification),
        where:
          e.recipient_id == ^id and
            (e.sender_id == ^id or n.state == "accepted") and
            (is_nil(e.expires_at) or e.expires_at > ^now) and
            (is_nil(e.max_displays) or e.display_count < e.max_displays),
        preload: [:sender],
        order_by: [desc: e.id]
      )

    query =
      case opts[:kind] do
        nil -> query
        kind -> where(query, [e], e.kind == ^kind)
      end

    query =
      case opts[:before_id] do
        nil -> query
        before_id -> where(query, [e], e.id < ^before_id)
      end

    query =
      case opts[:limit] do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc "Returns an envelope id usable as a history cursor only when it belongs to `user`."
  def history_cursor_id(%User{id: user_id}, public_id) when is_binary(public_id) do
    from(e in Envelope,
      where: e.recipient_id == ^user_id and e.public_id == ^public_id,
      select: e.id
    )
    |> Repo.one()
  end

  defp expired?(%Envelope{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now(:second)) != :gt
  end

  defp expired?(%Envelope{max_displays: max, display_count: count})
       when is_integer(max) and is_integer(count) do
    count >= max
  end

  defp expired?(_), do: false

  ## Message delivery policies

  def list_delivery_policies(%User{id: user_id}) do
    from(p in MessageDeliveryPolicy,
      where: p.user_id == ^user_id,
      order_by: [asc: p.subject_type, asc: p.subject_id]
    )
    |> Repo.all()
  end

  def put_delivery_policy(%User{} = user, subject_type, subject_id, attrs)
      when subject_type in ~w(contact group conversation) do
    with {:ok, subject_id} <- parse_policy_subject_id(subject_id),
         :ok <- authorize_policy_subject(user, subject_type, subject_id) do
      policy =
        Repo.get_by(MessageDeliveryPolicy,
          user_id: user.id,
          subject_type: subject_type,
          subject_id: subject_id
        ) ||
          %MessageDeliveryPolicy{
            user_id: user.id,
            subject_type: subject_type,
            subject_id: subject_id
          }

      policy
      |> MessageDeliveryPolicy.changeset(attrs)
      |> Repo.insert_or_update()
    end
  end

  def put_delivery_policy(_user, _subject_type, _subject_id, _attrs),
    do: {:error, :not_found}

  def delete_delivery_policy(%User{id: user_id} = user, subject_type, subject_id) do
    with {:ok, subject_id} <- parse_policy_subject_id(subject_id),
         :ok <- authorize_policy_subject(user, subject_type, subject_id) do
      from(p in MessageDeliveryPolicy,
        where:
          p.user_id == ^user_id and p.subject_type == ^subject_type and
            p.subject_id == ^subject_id
      )
      |> Repo.delete_all()

      :ok
    end
  end

  @doc "Returns whether `sender` may bypass the recipient's per-message consent prompt."
  def automatic_delivery?(%User{} = recipient, %User{} = sender) do
    if Social.friends?(recipient.id, sender.id) and is_nil(sender.pending_public_key) do
      case direct_policy(recipient.id, sender.id, "conversation") do
        %MessageDeliveryPolicy{acceptance: acceptance} -> acceptance == "automatic"
        nil -> contact_or_group_automatic?(recipient.id, sender.id)
      end
    else
      false
    end
  end

  def delivery_notification_mode(%User{} = recipient, %User{} = sender) do
    case effective_delivery_policy(recipient.id, sender.id) do
      %MessageDeliveryPolicy{notification: notification} -> notification
      nil -> "normal"
    end
  end

  defp effective_delivery_policy(recipient_id, sender_id) do
    direct_policy(recipient_id, sender_id, "conversation") ||
      direct_policy(recipient_id, sender_id, "contact") ||
      effective_group_policy(recipient_id, sender_id)
  end

  defp contact_or_group_automatic?(recipient_id, sender_id) do
    case direct_policy(recipient_id, sender_id, "contact") do
      %MessageDeliveryPolicy{acceptance: acceptance} ->
        acceptance == "automatic"

      nil ->
        policies = group_policies(recipient_id, sender_id)
        policies != [] and Enum.all?(policies, &(&1.acceptance == "automatic"))
    end
  end

  defp effective_group_policy(recipient_id, sender_id) do
    policies = group_policies(recipient_id, sender_id)

    Enum.find(policies, &(&1.acceptance == "ask")) ||
      Enum.find(policies, &(&1.notification != "silent")) ||
      List.first(policies)
  end

  defp direct_policy(user_id, subject_id, subject_type) do
    Repo.get_by(MessageDeliveryPolicy,
      user_id: user_id,
      subject_type: subject_type,
      subject_id: subject_id
    )
  end

  defp group_policies(user_id, sender_id) do
    from(p in MessageDeliveryPolicy,
      join: g in Veejr.Social.Group,
      on: g.id == p.subject_id,
      join: gm in Veejr.Social.GroupMember,
      on: gm.group_id == g.id,
      where:
        p.user_id == ^user_id and p.subject_type == "group" and g.owner_id == ^user_id and
          gm.user_id == ^sender_id
    )
    |> Repo.all()
  end

  defp parse_policy_subject_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_policy_subject_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :not_found}
    end
  end

  defp parse_policy_subject_id(_id), do: {:error, :not_found}

  defp authorize_policy_subject(user, subject_type, subject_id)
       when subject_type in ~w(contact conversation) do
    if Social.friends?(user.id, subject_id), do: :ok, else: {:error, :not_found}
  end

  defp authorize_policy_subject(user, "group", subject_id) do
    case Social.get_owned_group(user, subject_id) do
      %Veejr.Social.Group{} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp authorize_policy_subject(_user, _subject_type, _subject_id),
    do: {:error, :not_found}

  @doc """
  Records a successful client-side display of an envelope visible to `user`.
  Display-limited messages disappear from that user's history after the
  configured count is reached.
  """
  def record_display(%User{id: user_id}, public_id) when is_binary(public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id and e.recipient_id == ^user_id,
        left_join: n in assoc(e, :notification),
        preload: [notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      envelope.sender_id != user_id and not accepted?(envelope.notification) ->
        {:error, :unauthorized}

      is_nil(envelope.max_displays) ->
        {:ok, envelope}

      expired?(envelope) ->
        {:ok, envelope}

      true ->
        envelope
        |> Ecto.Changeset.change(display_count: envelope.display_count + 1)
        |> Repo.update()
    end
  end

  @doc """
  Metadata the browser needs to re-encrypt a sent batch edit.
  """
  def editable_batch(%User{id: user_id}, public_id) when is_binary(public_id) do
    with %Envelope{} = envelope <- Repo.get_by(Envelope, public_id: public_id, sender_id: user_id) do
      copies =
        from(e in Envelope,
          join: r in assoc(e, :recipient),
          where: e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id,
          select: %{
            public_id: e.public_id,
            recipient_id: r.id,
            public_key: r.public_key,
            handle:
              fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", r.host, r.username, r.username)
          },
          order_by: [asc: e.id]
        )
        |> Repo.all()

      {:ok, %{batch_id: envelope.batch_id, copies: copies}}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Replaces every copy in a sent batch with ciphertext produced in the browser.
  The server validates ownership and copy ids but never sees plaintext.
  """
  def edit_sent_batch(%User{id: user_id}, public_id, entries) when is_binary(public_id) do
    with %Envelope{} = envelope <- Repo.get_by(Envelope, public_id: public_id, sender_id: user_id),
         true <- is_list(entries) do
      now = DateTime.utc_now(:second)

      Repo.transaction(fn ->
        for entry <- entries, reduce: 0 do
          count ->
            entry_public_id = entry["public_id"] || entry[:public_id]

            {updated, _} =
              from(e in Envelope,
                where:
                  e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id and
                    e.public_id == ^entry_public_id
              )
              |> Repo.update_all(
                set: [
                  ciphertext: entry["ciphertext"] || entry[:ciphertext],
                  nonce: entry["nonce"] || entry[:nonce],
                  edited_at: now
                ]
              )

            count + updated
        end
      end)
      |> case do
        {:ok, count} when count > 0 -> {:ok, count}
        {:ok, _} -> {:error, :not_found}
        error -> error
      end
    else
      nil -> {:error, :not_found}
      _ -> {:error, :bad_request}
    end
  end

  @doc """
  Removes an envelope from the user's visible history.

  Senders delete the whole batch permanently, including copies that have not
  yet been fetched by remote recipients. Recipients keep the ciphertext from
  being displayed again by moving their notification to `declined`.
  """
  def delete_envelope(%User{id: user_id}, public_id) when is_binary(public_id) do
    envelope =
      from(e in Envelope,
        where: e.public_id == ^public_id,
        left_join: n in assoc(e, :notification),
        preload: [notification: n]
      )
      |> Repo.one()

    cond do
      is_nil(envelope) ->
        {:error, :not_found}

      envelope.sender_id == user_id ->
        {count, _} =
          from(e in Envelope,
            where: e.sender_id == ^user_id and e.batch_id == ^envelope.batch_id
          )
          |> Repo.delete_all()

        {:ok, {:deleted, count}}

      envelope.recipient_id == user_id and not is_nil(envelope.notification) ->
        envelope.notification
        |> Ecto.Changeset.change(state: "declined")
        |> Repo.update()
        |> case do
          {:ok, _notification} -> {:ok, :hidden}
          error -> error
        end

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  For a batch the user sent: who else received it (handles like `@bob` or
  `@carol@other.host`), so the sent view can say who it went to.
  """
  def batch_recipients(%User{id: id}, batch_id) do
    from(e in Envelope,
      join: u in assoc(e, :recipient),
      where: e.batch_id == ^batch_id and e.sender_id == ^id and e.recipient_id != ^id,
      select: %{username: u.username, host: u.host},
      order_by: u.username
    )
    |> Repo.all()
    |> Enum.map(&Veejr.Social.Address.handle/1)
  end

  ## Key rotation support

  @doc """
  Everything the user can decrypt, in the shape the rotation hook needs to
  re-encrypt it: ciphertext + the key it must be opened against.
  """
  def list_resealable(%User{} = user) do
    for envelope <- list_history(user) do
      %{
        public_id: envelope.public_id,
        kind: envelope.kind,
        ciphertext: envelope.ciphertext,
        nonce: envelope.nonce,
        peer_key: peer_key(envelope, user)
      }
    end
  end

  @doc """
  Replaces ciphertext with copies re-encrypted (client-side) to the user's
  new key. Only the user's own received/self copies are touched.
  """
  def reseal_envelopes(%User{id: user_id}, entries) when is_list(entries) do
    {:ok, count} =
      Repo.transaction(fn ->
        for entry <- entries, reduce: 0 do
          count ->
            public_id = entry["public_id"] || entry[:public_id]

            {n, _} =
              from(e in Envelope, where: e.public_id == ^public_id and e.recipient_id == ^user_id)
              |> Repo.update_all(
                set: [
                  ciphertext: entry["ciphertext"] || entry[:ciphertext],
                  nonce: entry["nonce"] || entry[:nonce],
                  resealed: true
                ]
              )

            count + n
        end
      end)

    {:ok, count}
  end

  @doc """
  Deletes every envelope copy addressed to the user (key reset: they are
  undecryptable forever). Copies held by other recipients are untouched.
  """
  def purge_received_envelopes(%User{id: user_id}) do
    {count, _} = from(e in Envelope, where: e.recipient_id == ^user_id) |> Repo.delete_all()
    {:ok, count}
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
