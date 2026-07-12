defmodule VeejrWeb.RecipientResolverTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.Accounts
  alias VeejrWeb.RecipientResolver

  defp user_with_keys(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64("pub-" <> username),
        "enc_secret_key" => Base.encode64("wrapped-" <> username),
        "key_salt" => Base.encode64("salt"),
        "key_nonce" => Base.encode64("nonce")
      })

    user
  end

  test "resolves the current account when requested" do
    alice = user_with_keys("alice")

    assert %{recipients: [recipient], missing_keys: []} =
             RecipientResolver.resolve(alice, %{"include_self" => true})

    assert recipient.id == to_string(alice.id)
    assert recipient.username == "alice"
    assert recipient.public_key == alice.public_key
  end

  test "does not include the current account unless requested" do
    alice = user_with_keys("alice")

    assert %{recipients: [], missing_keys: []} = RecipientResolver.resolve(alice, %{})
  end
end
