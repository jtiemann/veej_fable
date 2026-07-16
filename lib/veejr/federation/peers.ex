defmodule Veejr.Federation.Peers do
  @moduledoc """
  Signing keys of other instances, pinned on first contact.

  Trust-on-first-use: the first time an instance is seen, its `/api/instance`
  is fetched (over TLS in production) and the reported signing key is pinned.
  From then on every request claiming that authority must verify against the
  pinned key — a changed key is a hard failure, never a silent swap.
  """

  alias Veejr.Federation.Client
  alias Veejr.Repo

  defmodule Peer do
    use Ecto.Schema

    schema "peers" do
      field :authority, :string
      field :public_key, :string
      field :blocked_at, :utc_datetime
      belongs_to :blocked_by, Veejr.Accounts.User

      timestamps(type: :utc_datetime)
    end
  end

  @doc "Returns the pinned signing key (base64) for an authority, fetching and pinning on first contact."
  def signing_key(authority) do
    with :ok <- allow(authority) do
      case Repo.get_by(Peer, authority: authority) do
        %Peer{public_key: key} -> {:ok, key}
        nil -> pin(authority)
      end
    end
  end

  @doc "Returns an error when federation with an authority is administratively blocked."
  def allow(authority) when is_binary(authority) do
    case Repo.get_by(Peer, authority: authority) do
      %Peer{blocked_at: blocked_at} when not is_nil(blocked_at) -> {:error, :peer_blocked}
      _ -> :ok
    end
  end

  defp pin(authority) do
    with {:ok, %{"public_key" => key}} when is_binary(key) <-
           Client.get_json(authority, "/api/instance") do
      %Peer{authority: authority, public_key: key}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:authority)
      |> Repo.insert()
      |> case do
        {:ok, _} -> {:ok, key}
        {:error, _} -> signing_key(authority)
      end
    else
      {:ok, _} -> {:error, :peer_has_no_key}
      error -> error
    end
  end
end
