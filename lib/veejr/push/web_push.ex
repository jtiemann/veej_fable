defmodule Veejr.Push.WebPush do
  @moduledoc """
  Web Push protocol, implemented directly on OTP `:crypto`:

    * payload encryption per RFC 8291 (`aes128gcm`: ECDH P-256 + HKDF +
      AES-128-GCM), verified against the RFC's Appendix A test vector
    * VAPID (RFC 8292): ES256-signed JWT identifying this instance to the
      push service

  Push payloads in veejr are content-free (sender handle + kind), matching
  the pull model — but they are encrypted anyway, as the spec requires, so
  the push service (Google/Mozilla/Apple) sees nothing at all.
  """

  alias Veejr.Federation.Identity

  @record_size 4096
  @jwt_ttl_seconds 12 * 60 * 60

  ## Encryption (RFC 8291)

  @doc """
  Encrypts `plaintext` for a browser subscription. `p256dh` and `auth` are
  the base64url values from `PushSubscription.toJSON().keys`.

  `opts` may fix `:keypair` (`{as_public, as_private}`) and `:salt` — used
  by the RFC test vector; production callers let both be random.
  """
  def encrypt(plaintext, p256dh, auth, opts \\ []) do
    ua_public = Base.url_decode64!(p256dh, padding: false)
    auth_secret = Base.url_decode64!(auth, padding: false)

    {as_public, as_private} =
      Keyword.get_lazy(opts, :keypair, fn -> :crypto.generate_key(:ecdh, :secp256r1) end)

    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, :secp256r1)

    # HKDF chain exactly as RFC 8291 §3.3–3.4 (single-block expands).
    prk_key = hmac(auth_secret, ecdh_secret)
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hmac(prk_key, key_info <> <<1>>)
    prk = hmac(salt, ikm)
    cek = binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

    # single record; 0x02 marks the final-record padding delimiter
    record = plaintext <> <<2>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, record, <<>>, true)

    # aes128gcm content-coding header (RFC 8188) + ciphertext
    salt <>
      <<@record_size::unsigned-32>> <> <<byte_size(as_public)>> <> as_public <> ciphertext <> tag
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  ## VAPID (RFC 8292)

  @doc "The instance's VAPID public key, base64url — what the browser passes as `applicationServerKey`."
  def vapid_public_key do
    {public, _secret} = Identity.vapid_keypair()
    Base.url_encode64(public, padding: false)
  end

  @doc "ES256 JWT authorizing this instance to the push service at `audience`."
  def vapid_jwt(audience) do
    {_public, secret} = Identity.vapid_keypair()

    header = b64url(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      b64url(
        Jason.encode!(%{
          aud: audience,
          exp: System.system_time(:second) + @jwt_ttl_seconds,
          sub: Application.get_env(:veejr, :push_contact, "mailto:admin@#{Veejr.instance_host()}")
        })
      )

    signing_input = header <> "." <> claims
    der_signature = :crypto.sign(:ecdsa, :sha256, signing_input, [secret, :secp256r1])
    signing_input <> "." <> b64url(der_to_raw_signature(der_signature))
  end

  @doc "The `aud` claim for a push endpoint: its origin."
  def audience(endpoint) do
    uri = URI.parse(endpoint)

    if (uri.scheme == "https" and uri.port == 443) or (uri.scheme == "http" and uri.port == 80) do
      "#{uri.scheme}://#{uri.host}"
    else
      "#{uri.scheme}://#{uri.host}:#{uri.port}"
    end
  end

  # JOSE wants raw r||s (32+32 bytes); :crypto emits ASN.1 DER.
  def der_to_raw_signature(<<0x30, _len, 0x02, rlen, rest::binary>>) do
    <<r::binary-size(^rlen), 0x02, slen, s::binary-size(slen)>> = rest
    pad32(r) <> pad32(s)
  end

  defp pad32(int_bytes) do
    trimmed =
      int_bytes
      |> :binary.bin_to_list()
      |> Enum.drop_while(&(&1 == 0))
      |> :erlang.list_to_binary()

    <<0::size((32 - byte_size(trimmed)) * 8), trimmed::binary>>
  end

  defp b64url(data), do: Base.url_encode64(data, padding: false)

  ## Delivery

  @doc """
  Sends an encrypted push message to a subscription endpoint. Returns
  `{:ok, status}` or `{:error, reason}`; 404/410 mean the subscription is
  gone and should be pruned.
  """
  def send_push(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, payload_map) do
    body = encrypt(Jason.encode!(payload_map), p256dh, auth)
    aud = audience(endpoint)

    headers = [
      {"ttl", "43200"},
      {"urgency", "normal"},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"authorization", "vapid t=#{vapid_jwt(aud)}, k=#{vapid_public_key()}"}
    ]

    options =
      [url: endpoint, body: body, headers: headers, retry: false, receive_timeout: 10_000] ++
        Application.get_env(:veejr, :push_req_options, [])

    case Req.post(Req.new(options)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, status}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end
end
