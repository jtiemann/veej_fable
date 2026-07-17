defmodule Veejr.Federation do
  @moduledoc """
  Instance-to-instance protocol. The community server and personal instances
  are peers speaking exactly this — there is no special role.

  ## Trust model (MVP)

  Incoming requests claim an origin (`from.username` + `from.authority`).
  Nothing in the payload is trusted for identity: the receiving instance
  always calls back to the claimed authority's public directory
  (`/api/directory/:username`) and uses *that* public key, pinned on first
  contact. Impersonating `alice@A` therefore requires controlling A (or its
  DNS/TLS), not just sending a request. Envelope URLs are never taken from
  payloads either — they are constructed from the claimed authority and the
  envelope's public id. Signed requests (per-instance keys) are the next
  hardening step.

  ## Delivery model

  Envelope ciphertext stays on the sender's instance. The recipient's
  instance stores only a content-free stub + notification; ciphertext is
  fetched from the origin only after the recipient explicitly requests it.
  A declined message never leaves the sender's server.
  """

  require Logger

  alias Veejr.Accounts.User
  alias Veejr.Federation.{Client, Peers}
  alias Veejr.Repo
  alias Veejr.Social.Address

  ## Remote users

  @doc """
  Finds or creates the local row for a remote user, verifying against their
  home instance's directory (callback verification + key pinning).

  Returns `{:error, :key_changed}` if the directory now reports a different
  key than the one pinned earlier — never silently swap encryption keys.
  """
  def ensure_remote_user(username, authority) do
    with :ok <- Peers.allow(authority),
         {:ok, entry} <- Client.get_json(authority, "/api/directory/#{username}") do
      case Repo.get_by(User, username: username, host: authority) do
        nil ->
          create_remote_user(username, authority, entry)

        %User{public_key: pinned} = user when pinned == nil ->
          user
          |> Ecto.Changeset.change(public_key: entry["public_key"])
          |> Repo.update()

        %User{public_key: pinned} = user ->
          if pinned == entry["public_key"] do
            {:ok, user}
          else
            Logger.warning("federation: pinned key mismatch for #{username}@#{authority}")
            {:error, :key_changed}
          end
      end
    end
  end

  defp create_remote_user(username, authority, entry) do
    %User{}
    |> Ecto.Changeset.change(
      email: "remote+#{username}@#{String.replace(authority, ":", ".")}.invalid",
      username: username,
      host: authority,
      display_name: entry["display_name"],
      public_key: entry["public_key"]
    )
    |> Ecto.Changeset.unique_constraint(:username, name: :users_username_host_index)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      # raced with another request creating the same remote user
      {:error, _} -> {:ok, Repo.get_by!(User, username: username, host: authority)}
    end
  end

  ## Outgoing deliveries

  def deliver_friend_request(%User{host: nil} = from, %User{host: authority} = to)
      when is_binary(authority) do
    post(authority, "/api/federation/friend_request", %{
      from: %{username: from.username, authority: Veejr.instance_authority()},
      to: to.username
    })
  end

  def deliver_friend_response(%User{host: nil} = from, %User{host: authority} = to, action)
      when is_binary(authority) and action in ["accepted", "declined"] do
    Veejr.Federation.Outbox.deliver(authority, "/api/federation/friend_response", %{
      from: %{username: from.username, authority: Veejr.instance_authority()},
      to: to.username,
      action: action
    })
  end

  @doc """
  Announces an envelope to a remote recipient's instance. Unreachable peers
  get the notify parked in the outbox and retried automatically.
  """
  def deliver_notify(envelope, %User{host: authority} = recipient) when is_binary(authority) do
    Veejr.Federation.Outbox.deliver(authority, "/api/federation/notify", %{
      from: %{username: envelope.sender.username, authority: Veejr.instance_authority()},
      to: recipient.username,
      kind: envelope.kind,
      public_id: envelope.public_id
    })
  end

  defp post(authority, path, payload) do
    with :ok <- Peers.allow(authority) do
      case Client.post_json(authority, path, payload) do
        {:ok, _body} ->
          :ok

        {:error, reason} = error ->
          Logger.warning("federation: POST #{authority}#{path} failed: #{inspect(reason)}")
          error
      end
    end
  end

  @doc """
  Tells every instance hosting a friend of `user` that their key changed.
  Receivers hold the new key as *pending* until a human confirms it.
  """
  def announce_key_update(%User{host: nil} = user) do
    hosts =
      user
      |> Veejr.Social.list_friends()
      |> Enum.map(& &1.host)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for host <- hosts do
      Veejr.Federation.Outbox.deliver(host, "/api/federation/key_update", %{
        from: %{username: user.username, authority: Veejr.instance_authority()},
        public_key: user.public_key
      })
    end

    :ok
  end

  @doc "Notifies remote friends that a local user has moved to a new authority."
  def announce_account_move(%User{host: nil} = user, new_authority) do
    hosts =
      user
      |> Veejr.Social.list_friends()
      |> Enum.map(& &1.host)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    announce_account_move(user, new_authority, hosts)
  end

  def announce_account_move(%User{host: nil} = user, new_authority, hosts) do
    Enum.each(hosts, fn host ->
      Veejr.Federation.Outbox.deliver(host, "/api/federation/account_move", %{
        from: %{username: user.username, authority: Veejr.instance_authority()},
        new_authority: new_authority
      })
    end)

    :ok
  end

  @doc "Handles a signed address-change notice for an existing remote friend."
  def handle_account_move(
        %{
          "from" => %{"username" => username, "authority" => old_authority},
          "new_authority" => new_authority
        },
        verified_authority
      ) do
    with :ok <- validate_origin(username, old_authority, verified_authority),
         %User{} = old_contact <-
           Repo.get_by(User, username: username, host: old_authority) ||
             {:error, :unknown_recipient},
         true <- has_local_friend?(old_contact) || {:error, :not_friends},
         {:ok, replacement} <- ensure_remote_user(username, new_authority),
         true <- replacement.public_key == old_contact.public_key || {:error, :key_changed},
         {:ok, summary} <- Veejr.Social.relocate_contact(old_contact, replacement) do
      {:ok, summary}
    end
  end

  def handle_account_move(_, _), do: {:error, :bad_request}

  defp has_local_friend?(contact) do
    contact
    |> Veejr.Social.list_friends()
    |> Enum.any?(&is_nil(&1.host))
  end

  @doc "Handles a key-change announcement from a verified peer."
  def handle_key_update(
        %{
          "from" => %{"username" => username, "authority" => authority},
          "public_key" => new_key
        },
        verified_authority
      )
      when is_binary(new_key) do
    with :ok <- validate_origin(username, authority, verified_authority),
         %User{} = remote <-
           Repo.get_by(User, username: username, host: authority) || {:error, :unknown_recipient} do
      cond do
        remote.public_key == new_key ->
          {:ok, :unchanged}

        true ->
          remote
          |> Ecto.Changeset.change(pending_public_key: new_key)
          |> Repo.update()
      end
    end
  end

  def handle_key_update(_, _), do: {:error, :bad_request}

  @doc """
  Fetches the ciphertext of a remote envelope from its origin instance. The
  URL is built from the pinned sender host — never from request payloads.
  """
  def fetch_envelope_content(%{public_id: public_id, sender: %User{host: authority}})
      when is_binary(authority) do
    with :ok <- Peers.allow(authority),
         {:ok, body} <- Client.get_json(authority, "/api/envelopes/#{public_id}"),
         %{"ciphertext" => ct, "nonce" => nonce} when is_binary(ct) and is_binary(nonce) <- body do
      {:ok, ct, nonce}
    else
      %{} -> {:error, :malformed}
      error -> error
    end
  end

  ## Incoming handlers (called by FederationController)
  #
  # `verified_authority` is the peer whose signature the FederationAuth plug
  # checked. Payload origin claims must match it — a signed request from B
  # cannot speak for users of C.

  def handle_friend_request(
        %{
          "from" => %{"username" => username, "authority" => authority},
          "to" => to
        },
        verified_authority
      )
      when is_binary(username) and is_binary(authority) and is_binary(to) do
    with :ok <- validate_origin(username, authority, verified_authority),
         {:ok, remote} <- ensure_remote_user(username, authority),
         %User{host: nil} = local <-
           Veejr.Accounts.get_user_by_username(to) || {:error, :unknown_recipient} do
      Veejr.Social.receive_remote_friend_request(remote, local)
    end
  end

  def handle_friend_request(_, _), do: {:error, :bad_request}

  def handle_friend_response(
        %{
          "from" => %{"username" => username, "authority" => authority},
          "to" => to,
          "action" => action
        },
        verified_authority
      )
      when action in ["accepted", "declined"] do
    with :ok <- validate_origin(username, authority, verified_authority),
         {:ok, remote} <- ensure_remote_user(username, authority),
         %User{host: nil} = local <-
           Veejr.Accounts.get_user_by_username(to) || {:error, :unknown_recipient} do
      Veejr.Social.receive_remote_friend_response(remote, local, action)
    end
  end

  def handle_friend_response(_, _), do: {:error, :bad_request}

  def handle_notify(
        %{
          "from" => %{"username" => username, "authority" => authority},
          "to" => to,
          "kind" => kind,
          "public_id" => public_id
        },
        verified_authority
      )
      when is_binary(public_id) do
    with :ok <- validate_origin(username, authority, verified_authority),
         {:ok, remote} <- ensure_remote_user(username, authority),
         %User{host: nil} = local <-
           Veejr.Accounts.get_user_by_username(to) || {:error, :unknown_recipient},
         true <- Veejr.Social.friends?(remote.id, local.id) || {:error, :not_friends} do
      Veejr.Messaging.receive_remote_notify(remote, local, kind, public_id)
    end
  end

  def handle_notify(_, _), do: {:error, :bad_request}

  # The claimed origin must be a well-formed remote address AND the same
  # authority whose signature was verified on this request.
  defp validate_origin(username, authority, verified_authority) do
    with true <- authority == verified_authority || {:error, :origin_mismatch},
         {:remote, _, _} <- Address.parse("#{username}@#{authority}") do
      :ok
    else
      {:error, :origin_mismatch} -> {:error, :origin_mismatch}
      _ -> {:error, :bad_request}
    end
  end
end
