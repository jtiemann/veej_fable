defmodule Veejr.Federation.Identity do
  @moduledoc """
  This instance's own cryptographic identity.

  Two keypairs, generated lazily on first use and stored in
  `instance_credentials`:

    * `ed25519` — signs outgoing federation requests
    * `vapid_p256` — signs Web Push VAPID JWTs

  Signature scheme for federation (`sign_request/3` / `verify_request/5`):

      message = "veejr-v1|" <> authority <> "|" <> path <> "|" <> timestamp
                <> "|" <> Base64(SHA256(raw_body))

  where `authority` is the *sender's* authority. Binding the path and a body
  hash prevents replaying a signature onto a different endpoint or payload;
  the timestamp bounds the replay window.
  """

  import Ecto.Query, warn: false

  alias Veejr.Repo

  defmodule Credential do
    use Ecto.Schema

    schema "instance_credentials" do
      field :kind, :string
      field :public_key, :string
      field :secret_key, :string, redact: true

      timestamps(type: :utc_datetime)
    end
  end

  @doc "This instance's Ed25519 public signing key, base64."
  def signing_public_key do
    {public, _secret} = keypair("ed25519")
    Base.encode64(public)
  end

  @doc "Signs a federation request. Returns the signature, base64."
  def sign_request(path, timestamp, raw_body) do
    {_public, secret} = keypair("ed25519")
    message = request_message(Veejr.instance_authority(), path, timestamp, raw_body)

    :crypto.sign(:eddsa, :none, message, [secret, :ed25519])
    |> Base.encode64()
  end

  @doc "Verifies a peer's request signature against their pinned public key."
  def verify_request(
        peer_public_key_b64,
        peer_authority,
        path,
        timestamp,
        raw_body,
        signature_b64
      ) do
    with {:ok, public} <- Base.decode64(peer_public_key_b64),
         {:ok, signature} <- Base.decode64(signature_b64) do
      message = request_message(peer_authority, path, timestamp, raw_body)
      :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519])
    else
      _ -> false
    end
  end

  defp request_message(authority, path, timestamp, raw_body) do
    body_hash = Base.encode64(:crypto.hash(:sha256, raw_body))
    "veejr-v1|#{authority}|#{path}|#{timestamp}|#{body_hash}"
  end

  @doc "The VAPID P-256 keypair as raw binaries `{public_65_bytes, secret}`."
  def vapid_keypair do
    keypair("vapid_p256")
  end

  @doc "Fetches (or generates on first use) the keypair of the given kind."
  def keypair(kind) do
    case Repo.get_by(Credential, kind: kind) do
      nil -> generate(kind)
      cred -> {Base.decode64!(cred.public_key), Base.decode64!(cred.secret_key)}
    end
  end

  defp generate(kind) do
    {public, secret} =
      case kind do
        "ed25519" -> :crypto.generate_key(:eddsa, :ed25519)
        "vapid_p256" -> :crypto.generate_key(:ecdh, :secp256r1)
      end

    %Credential{
      kind: kind,
      public_key: Base.encode64(public),
      secret_key: Base.encode64(secret)
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:kind)
    |> Repo.insert()
    |> case do
      {:ok, _} -> {public, secret}
      # raced with a concurrent first use — read the winner's keys
      {:error, _} -> keypair(kind)
    end
  end
end
