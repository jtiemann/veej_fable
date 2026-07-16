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
end
