defmodule Veejr.Admin do
  @moduledoc "Read-only operational information for instance administration."

  import Ecto.Query, warn: false

  alias Veejr.Accounts.{Invitation, User}
  alias Veejr.Federation.Outbox
  alias Veejr.Federation.Peers.Peer
  alias Veejr.Messaging.{Blob, Envelope, Notification}
  alias Veejr.Repo

  @doc "Returns a content-free snapshot of instance usage and health."
  def snapshot do
    now = DateTime.utc_now(:second)
    week_ago = DateTime.add(now, -7, :day)

    {blob_count, blob_bytes} =
      Repo.one(from(b in Blob, select: {count(b.id), coalesce(sum(b.size), 0)}))

    %{
      captured_at: now,
      users: %{
        local: Repo.aggregate(from(u in User, where: is_nil(u.host)), :count),
        remote: Repo.aggregate(from(u in User, where: not is_nil(u.host)), :count),
        joined_last_7_days:
          Repo.aggregate(
            from(u in User, where: is_nil(u.host) and u.inserted_at >= ^week_ago),
            :count
          )
      },
      data: %{
        envelopes: Repo.aggregate(Envelope, :count),
        blobs: blob_count,
        blob_bytes: blob_bytes,
        pending_notifications:
          Repo.aggregate(from(n in Notification, where: n.state == "pending"), :count)
      },
      operations: %{
        active_invitations:
          Repo.aggregate(
            from(i in Invitation, where: is_nil(i.accepted_at) and i.expires_at > ^now),
            :count
          ),
        federation_queue: Outbox.pending_count(),
        pinned_peers: Repo.aggregate(Peer, :count)
      },
      health: %{
        database: database_health(),
        endpoint: process_health(VeejrWeb.Endpoint),
        federation_outbox: process_health(Outbox)
      },
      software: %{
        veejr: Veejr.version(),
        elixir: System.version(),
        otp: System.otp_release(),
        database: database_version()
      }
    }
  end

  defp database_health do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  defp database_version do
    case Ecto.Adapters.SQL.query(Repo, "SELECT sqlite_version()", []) do
      {:ok, %{rows: [[version]]}} -> "SQLite #{version}"
      _ -> "Unavailable"
    end
  end

  defp process_health(name) do
    if Process.whereis(name), do: :ok, else: :error
  end
end
