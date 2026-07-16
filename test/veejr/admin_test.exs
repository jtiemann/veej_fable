defmodule Veejr.AdminTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin, Repo}
  alias Veejr.Accounts.User
  alias Veejr.Federation.{Outbox, Peers}
  alias Veejr.Federation.Outbox.Delivery
  alias Veejr.Federation.Peers.Peer

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

    assert [%{action: "invitation.revoked", target_id: target_id, actor: actor}] =
             Admin.list_audit_events()

    assert target_id == invitation.id
    assert actor.id == admin.id

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

  test "administrator can explicitly expire an invitation" do
    admin = user_fixture()
    member = user_fixture()
    {:ok, invitation, token} = Accounts.create_invitation(admin)

    assert {:error, :unauthorized} = Admin.expire_invitation(member, invitation.id)
    assert {:ok, expired} = Admin.expire_invitation(admin, invitation.id)
    assert Admin.invitation_status(expired) == :expired
    refute Accounts.get_open_invitation(token)
    assert [%{action: "invitation.expired"}] = Admin.list_audit_events()
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
    assert account.last_web_authenticated_at
    assert account.storage_bytes == 0

    assert {:error, :unauthorized} = Admin.revoke_user_sessions(member, member.id)
    assert {:error, :protected_admin} = Admin.revoke_user_sessions(admin, admin.id)

    assert {:ok, result} = Admin.revoke_user_sessions(admin, member.id)
    assert result.web_count == 1
    assert result.device_count == 1
    assert [%{token: ^web_token}] = result.web_tokens

    assert [%{action: "sessions.revoked", details: details}] = Admin.list_audit_events()
    assert details["username"] == member.username
    assert details["web_sessions"] == 1
    assert details["device_sessions"] == 1

    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_and_api_session_by_access_token(api_tokens.access_token)
    assert Accounts.get_user!(member.id)
  end

  test "administrator can suspend and reactivate a member" do
    admin = user_fixture()
    member = user_fixture() |> set_password()
    web_token = Accounts.generate_user_session_token(member)
    {magic_token, _hashed_token} = generate_user_magic_link_token(member)

    {:ok, _device_session, api_tokens} =
      Accounts.create_api_device_session(member, %{
        "device_name" => "Test Pixel",
        "platform" => "android"
      })

    assert {:error, :unauthorized} = Admin.suspend_user(member, member.id)
    assert {:error, :protected_admin} = Admin.suspend_user(admin, admin.id)

    assert {:ok, result} = Admin.suspend_user(admin, member.id)
    assert result.web_count == 1
    assert result.device_count == 1
    assert result.user.suspended_at
    assert result.user.suspended_by_id == admin.id
    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_and_api_session_by_access_token(api_tokens.access_token)
    refute Accounts.get_user_by_email_and_password(member.email, valid_user_password())
    assert {:error, :already_suspended} = Admin.suspend_user(admin, member.id)

    assert {:ok, reactivated} = Admin.reactivate_user(admin, member.id)
    refute reactivated.suspended_at
    refute reactivated.suspended_by_id
    assert Accounts.get_user_by_email_and_password(member.email, valid_user_password())
    refute Accounts.get_user_by_session_token(web_token)
    assert {:error, :not_found} = Accounts.login_user_by_magic_link(magic_token)
    assert {:error, :not_suspended} = Admin.reactivate_user(admin, member.id)

    assert [reactivated_event, suspended_event] = Admin.list_audit_events()
    assert reactivated_event.action == "account.reactivated"
    assert suspended_event.action == "account.suspended"
    assert reactivated_event.target_id == member.id
    assert suspended_event.target_id == member.id
  end

  test "administrator can block and unblock a pinned federation peer" do
    admin = user_fixture()
    member = user_fixture()

    peer =
      %Peer{authority: "blocked.example", public_key: Base.encode64("peer-key")}
      |> Ecto.Changeset.change()
      |> Repo.insert!()

    Repo.insert!(%Delivery{
      authority: peer.authority,
      path: "/api/federation/notify",
      payload: "{}",
      attempts: 1,
      next_attempt_at: DateTime.utc_now(:second)
    })

    assert {:error, :unauthorized} = Admin.block_peer(member, peer.id)
    assert {:ok, result} = Admin.block_peer(admin, peer.id)
    assert result.peer.blocked_at
    assert result.peer.blocked_by_id == admin.id
    assert result.outbound_deliveries_dropped == 1
    assert {:error, :peer_blocked} = Peers.allow(peer.authority)
    assert Outbox.pending_count() == 0
    assert {:error, :peer_blocked} = Veejr.Federation.ensure_remote_user("alice", peer.authority)
    assert {:error, :already_blocked} = Admin.block_peer(admin, peer.id)

    assert {:ok, allowed} = Admin.unblock_peer(admin, peer.id)
    refute allowed.blocked_at
    refute allowed.blocked_by_id
    assert :ok = Peers.allow(peer.authority)
    assert {:error, :not_blocked} = Admin.unblock_peer(admin, peer.id)

    assert [unblocked_event, blocked_event] = Admin.list_audit_events()
    assert unblocked_event.action == "peer.unblocked"
    assert blocked_event.action == "peer.blocked"
    assert blocked_event.details["authority"] == peer.authority
    assert blocked_event.details["outbound_deliveries_dropped"] == 1
  end

  test "administrator can retry queued federation deliveries and review key changes" do
    admin = user_fixture()

    remote =
      Repo.insert!(%User{
        email: "remote@remote.example",
        username: "remote_user",
        host: "remote.example",
        public_key: "old-key",
        pending_public_key: "new-key"
      })

    Repo.insert!(%Delivery{
      authority: remote.host,
      path: "/api/federation/notify",
      payload: Jason.encode!(%{"ok" => true}),
      attempts: 1,
      next_attempt_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)
    })

    Req.Test.stub(Veejr.FederationStub, fn conn -> Req.Test.json(conn, %{ok: true}) end)

    assert [^remote] = Admin.list_pending_key_changes()
    assert {:ok, result} = Admin.retry_federation(admin)
    assert result.scheduled == 1
    assert result.succeeded == 1
    assert result.remaining == 0
    assert [%{action: "federation.retried", details: details}] = Admin.list_audit_events()
    assert details["result"] == "success"
  end
end
