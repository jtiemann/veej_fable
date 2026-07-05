defmodule Veejr.WebPushTest do
  use Veejr.DataCase, async: false

  alias Veejr.Push.WebPush

  # RFC 8291, Appendix A: complete worked example.
  @plaintext "When I grow up, I want to be a watermelon"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth_secret "BTBZMqHH6r4Tts7J_aSIgg"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @expected_body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  defp d(b64url), do: Base.url_decode64!(b64url, padding: false)

  test "encrypt matches the RFC 8291 test vector byte for byte" do
    body =
      WebPush.encrypt(@plaintext, @ua_public, @auth_secret,
        keypair: {d(@as_public), d(@as_private)},
        salt: d(@salt)
      )

    assert Base.url_encode64(body, padding: false) == @expected_body
  end

  test "vapid_jwt is a valid ES256 JWT verifiable with the instance VAPID key" do
    jwt = WebPush.vapid_jwt("https://push.example")
    [header, claims, signature] = String.split(jwt, ".")

    assert %{"alg" => "ES256", "typ" => "JWT"} =
             Jason.decode!(Base.url_decode64!(header, padding: false))

    decoded_claims = Jason.decode!(Base.url_decode64!(claims, padding: false))
    assert decoded_claims["aud"] == "https://push.example"
    assert decoded_claims["exp"] > System.system_time(:second)
    assert decoded_claims["sub"] =~ "mailto:"

    # verify the signature with the public key (raw r||s back to DER)
    {public, _} = Veejr.Federation.Identity.vapid_keypair()
    raw = Base.url_decode64!(signature, padding: false)
    <<r::binary-size(32), s::binary-size(32)>> = raw
    der = raw_to_der(r, s)

    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [public, :secp256r1])
  end

  test "audience derivation" do
    assert WebPush.audience("https://fcm.googleapis.com/fcm/send/abc123") ==
             "https://fcm.googleapis.com"

    assert WebPush.audience("http://localhost:9999/push/xyz") == "http://localhost:9999"
  end

  describe "subscription lifecycle" do
    import Veejr.AccountsFixtures

    # a real browser-shaped subscription: P-256 key + 16-byte auth secret
    defp browser_subscription(endpoint) do
      {ua_public, _} = :crypto.generate_key(:ecdh, :secp256r1)

      %{
        "endpoint" => endpoint,
        "keys" => %{
          "p256dh" => Base.url_encode64(ua_public, padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      }
    end

    test "notify pushes to subscriptions and prunes dead ones" do
      user = user_fixture()
      {:ok, _} = Veejr.Push.subscribe(user, browser_subscription("https://push.example/ok"))
      {:ok, _} = Veejr.Push.subscribe(user, browser_subscription("https://push.example/dead"))
      assert Veejr.Push.subscription_count(user) == 2

      sender = user_fixture(%{username: "sender"})

      Req.Test.stub(Veejr.PushStub, fn conn ->
        case conn.request_path do
          "/ok" ->
            # the push service receives opaque bytes + VAPID auth
            # (content-encoding is verified against a real transport, not
            # here: Req's plug test adapter consumes that header)
            assert ["application/octet-stream"] = Plug.Conn.get_req_header(conn, "content-type")
            assert ["vapid t=" <> _] = Plug.Conn.get_req_header(conn, "authorization")
            Plug.Conn.send_resp(conn, 201, "")

          "/dead" ->
            Plug.Conn.send_resp(conn, 410, "gone")
        end
      end)

      notification = %{
        user_id: user.id,
        envelope: %{kind: "message", sender: %{username: sender.username, host: nil}}
      }

      assert :ok = Veejr.Push.notify(notification)
      assert Veejr.Push.subscription_count(user) == 1
    end
  end

  defp raw_to_der(r, s) do
    ri = der_int(r)
    si = der_int(s)
    body = <<0x02, byte_size(ri)>> <> ri <> <<0x02, byte_size(si)>> <> si
    <<0x30, byte_size(body)>> <> body
  end

  defp der_int(<<first, _rest::binary>> = bytes) when first >= 0x80, do: <<0>> <> bytes

  defp der_int(bytes) do
    case :binary.bin_to_list(bytes) |> Enum.drop_while(&(&1 == 0)) do
      [] -> <<0>>
      [first | _] = list when first >= 0x80 -> <<0>> <> :erlang.list_to_binary(list)
      list -> :erlang.list_to_binary(list)
    end
  end
end
