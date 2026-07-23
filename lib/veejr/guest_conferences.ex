defmodule Veejr.GuestConferences do
  @moduledoc """
  Immediate, host-admitted conferences with one temporary email guest.

  The emailed capability authorizes only the guest lobby and guest side of
  its eventual call. The guest's browser creates an ephemeral encryption
  identity; no hidden user account is created.
  """

  import Ecto.Query, warn: false

  alias Veejr.Accounts.User
  alias Veejr.GuestConferences.GuestConference
  alias Veejr.Repo

  @lifetime_seconds 2 * 60 * 60

  def change_invitation(attrs \\ %{}) do
    GuestConference.invitation_changeset(%GuestConference{}, attrs)
  end

  def create_invitation(%User{host: nil} = host, attrs) do
    token = random_token()

    create_attrs = %{
      host_id: host.id,
      invited_email: Map.get(attrs, "invited_email") || Map.get(attrs, :invited_email),
      public_id: random_id(),
      token_hash: token_hash(token),
      expires_at: DateTime.add(DateTime.utc_now(:second), @lifetime_seconds, :second)
    }

    case Repo.insert(GuestConference.create_changeset(%GuestConference{}, create_attrs)) do
      {:ok, conference} -> {:ok, %{conference | host: host}, token}
      error -> error
    end
  end

  def get_for_host(%User{id: host_id}, public_id) when is_binary(public_id) do
    case Repo.get_by(GuestConference, public_id: public_id, host_id: host_id) do
      nil -> {:error, :not_found}
      conference -> {:ok, Repo.preload(conference, [:host, :call])}
    end
  end

  def get_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    now = DateTime.utc_now(:second)

    Repo.one(
      from(g in GuestConference,
        where:
          g.token_hash == ^token_hash(token) and g.expires_at > ^now and
            g.state not in ["revoked", "declined"],
        preload: [:host, :call]
      )
    )
  end

  def get_by_token(_token), do: nil

  def put_waiting(%GuestConference{state: state} = conference, attrs)
      when state in ["sent", "waiting"] do
    conference
    |> GuestConference.waiting_changeset(attrs)
    |> Ecto.Changeset.put_change(:state, "waiting")
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated = Repo.preload(updated, :host)
        broadcast(updated, {:guest_conference_waiting, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def put_waiting(%GuestConference{}, _attrs), do: {:error, :unavailable}

  def mark_admitted(%GuestConference{} = conference) do
    conference
    |> Ecto.Changeset.change(
      state: "admitted",
      admitted_at: DateTime.utc_now(:second)
    )
    |> Repo.update()
  end

  def decline(%User{id: host_id}, %GuestConference{host_id: host_id} = conference) do
    update_terminal(conference, "declined")
  end

  def decline(%User{}, %GuestConference{}), do: {:error, :not_found}

  def revoke(%User{id: host_id}, %GuestConference{host_id: host_id} = conference) do
    update_terminal(conference, "revoked")
  end

  def revoke(%User{}, %GuestConference{}), do: {:error, :not_found}

  def mark_ended(%GuestConference{} = conference) do
    if conference.state == "ended" do
      {:ok, conference}
    else
      conference
      |> Ecto.Changeset.change(
        state: "ended",
        ended_at: DateTime.utc_now(:second),
        public_key: nil
      )
      |> Repo.update()
      |> tap(fn
        {:ok, updated} -> broadcast(updated, {:guest_conference_ended, updated})
        _ -> :ok
      end)
    end
  end

  def mark_joined(%GuestConference{} = conference) do
    conference
    |> Ecto.Changeset.change(joined_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def subscribe(%GuestConference{public_id: public_id}), do: subscribe(public_id)

  def subscribe(public_id) when is_binary(public_id) do
    Phoenix.PubSub.subscribe(Veejr.PubSub, topic(public_id))
  end

  def broadcast_admitted(%GuestConference{} = conference, call) do
    broadcast(conference, {:guest_conference_admitted, call.public_id})
  end

  defp update_terminal(conference, state) do
    conference
    |> Ecto.Changeset.change(state: state, ended_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast(updated, {:guest_conference_closed, state})
      _ -> :ok
    end)
  end

  defp broadcast(conference, message) do
    Phoenix.PubSub.broadcast(Veejr.PubSub, topic(conference.public_id), message)
  end

  defp topic(public_id), do: "guest_conference:#{public_id}"
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
end
