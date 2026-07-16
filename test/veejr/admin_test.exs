defmodule Veejr.AdminTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin, Repo}
  alias Veejr.Accounts.User

  test "snapshot reports content-free instance metrics and health" do
    admin = user_fixture()

    Repo.insert!(%User{
      email: "remote@remote.example",
      username: "remote_contact",
      host: "remote.example"
    })

    {:ok, _invitation, _token} = Accounts.create_invitation(admin)

    snapshot = Admin.snapshot()

    assert snapshot.users.local == 1
    assert snapshot.users.remote == 1
    assert snapshot.users.joined_last_7_days == 1
    assert snapshot.operations.active_invitations == 1
    assert snapshot.operations.federation_queue == 0
    assert snapshot.health.database == :ok
    assert snapshot.health.endpoint == :ok
    assert snapshot.health.federation_outbox == :ok
    assert snapshot.software.database =~ "SQLite"
  end

  test "only the administrator can revoke an active invitation" do
    admin = user_fixture()
    member = user_fixture()
    {:ok, invitation, token} = Accounts.create_invitation(admin)

    assert Admin.invitation_status(invitation) == :active
    assert {:error, :unauthorized} = Admin.revoke_invitation(member, invitation.id)
    assert {:ok, revoked} = Admin.revoke_invitation(admin, invitation.id)
    assert Admin.invitation_status(revoked) == :revoked
    refute Accounts.get_open_invitation(token)

    assert {:error, :invite_unavailable} =
             Accounts.register_user(valid_user_attributes(), token)
  end

  test "invitation status distinguishes accepted and expired invitations" do
    admin = user_fixture()
    {:ok, accepted, token} = Accounts.create_invitation(admin)
    {:ok, _user} = Accounts.register_user(valid_user_attributes(), token)
    accepted = Repo.reload!(accepted)

    {:ok, expired, _token} = Accounts.create_invitation(admin)

    expired =
      expired
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
      |> Repo.update!()

    assert Admin.invitation_status(accepted) == :accepted
    assert Admin.invitation_status(expired) == :expired
  end

  test "administrator can inspect and revoke a member's sessions" do
    admin = user_fixture()
    member = user_fixture()
    web_token = Accounts.generate_user_session_token(member)

    {:ok, _device_session, api_tokens} =
      Accounts.create_api_device_session(member, %{
        "device_name" => "Test Pixel",
        "platform" => "android",
        "app_version" => "test"
      })

    account = Enum.find(Admin.list_local_accounts(), &(&1.user.id == member.id))
    assert account.web_sessions == 1
    assert account.device_sessions == 1
    assert account.last_device_used_at

    assert {:error, :unauthorized} = Admin.revoke_user_sessions(member, member.id)
    assert {:error, :protected_admin} = Admin.revoke_user_sessions(admin, admin.id)

    assert {:ok, result} = Admin.revoke_user_sessions(admin, member.id)
    assert result.web_count == 1
    assert result.device_count == 1
    assert [%{token: ^web_token}] = result.web_tokens

    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_and_api_session_by_access_token(api_tokens.access_token)
    assert Accounts.get_user!(member.id)
  end
end
