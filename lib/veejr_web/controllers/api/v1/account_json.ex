defmodule VeejrWeb.Api.V1.AccountJSON do
  alias Veejr.Accounts.User

  def render(%User{} = user) do
    %{
      id: to_string(user.id),
      email: user.email,
      username: user.username,
      display_name: user.display_name,
      handle: "@#{user.username}",
      avatar_url: Veejr.Accounts.avatar_url(user),
      confirmed: not is_nil(user.confirmed_at),
      keys_configured: not is_nil(user.public_key),
      public_key: user.public_key,
      wrapped_key: wrapped_key(user)
    }
  end

  defp wrapped_key(%User{enc_secret_key: nil}), do: nil

  defp wrapped_key(%User{} = user) do
    %{
      ciphertext: user.enc_secret_key,
      salt: user.key_salt,
      nonce: user.key_nonce,
      kdf: %{name: "PBKDF2-SHA256", iterations: 310_000},
      wrap: "XSalsa20-Poly1305"
    }
  end
end
