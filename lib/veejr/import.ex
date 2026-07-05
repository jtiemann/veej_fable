defmodule Veejr.Import do
  @moduledoc """
  Restores a `Veejr.Export` zip into this instance — the migration path from
  a community server to a personal instance.

  What comes back:

    * the owner account (email, username, wrapped key material), already
      confirmed — unlock with the same passphrase as before
    * **ghost contacts**: local stub users for everyone who ever sent the
      owner an envelope, carrying just their username and public key so old
      ciphertext still decrypts. Ghosts cannot log in (their email is on a
      reserved `.invalid` domain) and hold no key material of their own.
      When federation lands, ghosts are the natural seed for remote contacts.
    * the full envelope history with original ids and timestamps; received
      envelopes get an already-`accepted` notification so history renders
    * the owner's own uploaded attachment blobs

  Friendships and groups are *not* recreated as live links — the friends
  still live on the old instance and there is no federation yet. Their data
  stays in the manifest for a future importer version.

  Idempotent-ish: envelopes and blobs are deduplicated by their public ids,
  so re-running an import does not duplicate history.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Veejr.Accounts.User
  alias Veejr.Messaging
  alias Veejr.Messaging.{Blob, Envelope, Notification}
  alias Veejr.Repo

  @supported_versions [1]

  @doc "Imports an export zip (binary). Returns `{:ok, summary}` or `{:error, reason}`."
  def from_zip(zip_binary) when is_binary(zip_binary) do
    with {:ok, files} <- unzip(zip_binary),
         {:ok, manifest} <- parse_manifest(files) do
      Repo.transaction(fn ->
        owner = create_owner!(manifest)
        ghosts = create_ghosts!(manifest, owner)
        envelope_count = import_envelopes!(manifest, owner, ghosts)
        blob_count = import_blobs!(files, owner)

        %{
          owner: owner.username,
          ghost_contacts: map_size(ghosts),
          envelopes: envelope_count,
          blobs: blob_count
        }
      end)
    end
  end

  defp unzip(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, files} -> {:ok, Map.new(files, fn {name, bin} -> {to_string(name), bin} end)}
      {:error, _} -> {:error, :not_a_zip}
    end
  end

  defp parse_manifest(%{"export.json" => json}) do
    case Jason.decode(json) do
      {:ok, %{"veejr_export" => v} = manifest} when v in @supported_versions -> {:ok, manifest}
      {:ok, %{"veejr_export" => v}} -> {:error, {:unsupported_version, v}}
      _ -> {:error, :invalid_manifest}
    end
  end

  defp parse_manifest(_files), do: {:error, :missing_manifest}

  defp create_owner!(%{"profile" => profile, "keys" => keys}) do
    if Repo.get_by(User, username: profile["username"]) ||
         Repo.get_by(User, email: profile["email"]) do
      Repo.rollback(:owner_already_exists)
    end

    %User{}
    |> User.registration_changeset(%{
      "email" => profile["email"],
      "username" => profile["username"],
      "display_name" => profile["display_name"]
    })
    |> User.keys_changeset(keys)
    |> Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
    |> case do
      {:ok, owner} -> owner
      {:error, changeset} -> Repo.rollback({:owner_invalid, changeset})
    end
  end

  # One remote-contact row per distinct envelope sender (keyed by their home
  # instance), so received ciphertext keeps a resolvable sender with a public
  # key to decrypt against. These are ordinary remote users — once federation
  # can reach their instance again, friendships can be re-established.
  defp create_ghosts!(%{"envelopes" => envelopes} = manifest, owner) do
    export_host = get_in(manifest, ["instance", "host"]) || "unknown.invalid"

    envelopes
    |> Enum.map(& &1["sender"])
    |> Enum.reject(&(&1["username"] == owner.username))
    |> Enum.uniq_by(&{&1["username"], &1["host"]})
    |> Map.new(fn sender ->
      username = sender["username"]
      host = sender["host"] || export_host

      ghost =
        Repo.get_by(User, username: username, host: host) ||
          Repo.insert!(
            Changeset.change(%User{},
              email: "remote+#{username}@#{String.replace(host, ":", ".")}.invalid",
              username: username,
              host: host,
              display_name: sender["display_name"],
              public_key: sender["public_key"]
            )
          )

      {{username, host}, ghost}
    end)
  end

  defp import_envelopes!(%{"envelopes" => envelopes} = manifest, owner, ghosts) do
    export_host = get_in(manifest, ["instance", "host"]) || "unknown.invalid"

    existing =
      from(e in Envelope, where: e.recipient_id == ^owner.id, select: e.public_id)
      |> Repo.all()
      |> MapSet.new()

    envelopes
    |> Enum.reject(&MapSet.member?(existing, &1["public_id"]))
    |> Enum.map(fn entry ->
      sender = entry["sender"]

      sender_id =
        if sender["username"] == owner.username,
          do: owner.id,
          else: ghosts[{sender["username"], sender["host"] || export_host}].id

      {:ok, inserted_at, _} = DateTime.from_iso8601(entry["inserted_at"])
      inserted_at = DateTime.truncate(inserted_at, :second)

      envelope =
        Repo.insert!(%Envelope{
          public_id: entry["public_id"],
          batch_id: entry["batch_id"],
          sender_id: sender_id,
          recipient_id: owner.id,
          kind: entry["kind"],
          ciphertext: entry["ciphertext"],
          nonce: entry["nonce"],
          inserted_at: inserted_at,
          updated_at: inserted_at
        })

      if sender_id != owner.id do
        Repo.insert!(%Notification{
          envelope_id: envelope.id,
          user_id: owner.id,
          state: "accepted"
        })
      end

      envelope
    end)
    |> length()
  end

  defp import_blobs!(files, owner) do
    dir = Messaging.blob_dir()
    File.mkdir_p!(dir)

    files
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "blobs/") end)
    |> Enum.reject(fn {name, _} ->
      public_id = blob_id(name)
      Repo.exists?(from(b in Blob, where: b.public_id == ^public_id))
    end)
    |> Enum.map(fn {name, binary} ->
      public_id = blob_id(name)
      path = Path.join(dir, public_id <> ".bin")
      File.write!(path, binary)

      Repo.insert!(%Blob{
        public_id: public_id,
        owner_id: owner.id,
        size: byte_size(binary),
        path: path
      })
    end)
    |> length()
  end

  defp blob_id(name), do: name |> Path.basename() |> Path.rootname(".bin")
end
