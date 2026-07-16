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
end
