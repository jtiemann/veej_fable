defmodule Veejr.InstanceSettingsTest do
  use Veejr.DataCase

  import Swoosh.TestAssertions
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Admin, InstanceSettings, Messaging, Operations, Repo}
  alias Veejr.Accounts.UserNotifier

  test "administrator settings control registration and invitation lifetime" do
    admin = user_fixture()
    member = user_fixture()

    attrs = %{
      "name" => "Around Town",
      "description" => "A private neighborhood instance",
      "registration_policy" => "invite_only",
      "invitation_lifetime_days" => "2",
      "max_upload_mb" => "10",
      "storage_quota_mb" => "100",
      "default_retention_hours" => "24",
      "mail_from_name" => "Around Town",
      "mail_from_address" => "hello@around.example"
    }

    assert {:error, :unauthorized} = Admin.update_instance_settings(member, attrs)
    assert {:ok, settings} = Admin.update_instance_settings(admin, attrs)
    assert settings.invitation_lifetime_hours == 48
    assert settings.max_upload_bytes == 10 * 1024 * 1024
    assert settings.storage_quota_bytes == 100 * 1024 * 1024
    assert Veejr.instance_name() == "Around Town"
    assert Veejr.instance_description() == "A private neighborhood instance"
    refute Veejr.registration_open?()

    assert {:error, :registration_closed} = Accounts.register_user(valid_user_attributes())
    assert {:ok, invitation, token} = Accounts.create_invitation(admin)
    remaining = DateTime.diff(invitation.expires_at, DateTime.utc_now(:second), :hour)
    assert remaining in 47..48
    assert {:ok, _invited} = Accounts.register_user(valid_user_attributes(), token)

    assert {:ok, _settings} =
             Admin.update_instance_settings(
               admin,
               Map.put(attrs, "registration_policy", "closed")
             )

    assert {:error, :invitations_closed} = Accounts.create_invitation(admin)
  end

  test "configured retention, upload size, storage quota, and sender identity are enforced" do
    admin = user_fixture()
    assert_email_sent()

    assert {:ok, _settings} =
             Admin.update_instance_settings(admin, %{
               "registration_policy" => "mode_default",
               "invitation_lifetime_days" => "7",
               "max_upload_mb" => "1",
               "storage_quota_mb" => "1",
               "default_retention_hours" => "12",
               "mail_from_name" => "Veejr Community",
               "mail_from_address" => "community@example.com"
             })

    assert {:ok, _batch_id, _deliveries} =
             Messaging.send_batch(admin, "message", [
               %{"recipient_id" => admin.id, "ciphertext" => "cipher", "nonce" => "nonce"}
             ])

    [envelope] = Messaging.list_history(admin)
    remaining = DateTime.diff(envelope.expires_at, DateTime.utc_now(:second), :hour)
    assert remaining in 11..12
    assert Messaging.max_blob_size() == 1024 * 1024

    settings = InstanceSettings.get()

    settings
    |> Ecto.Changeset.change(storage_quota_bytes: 5)
    |> Repo.update!()

    assert {:error, :storage_quota_exceeded} = Messaging.create_blob(admin, "123456")

    assert {:ok, _email} = UserNotifier.deliver_admin_test(admin)

    assert_email_sent(fn email ->
      assert email.from == {"Veejr Community", "community@example.com"}
      assert Enum.any?(email.to, fn {_name, address} -> address == admin.email end)
    end)
  end

  test "operational failures contain no recipient or message content" do
    assert {:ok, failure} = Operations.record_failure("email", "login_link", {:smtp, :timeout})
    assert failure.channel == "email"
    assert failure.operation == "login_link"
    assert failure.error =~ "timeout"
    refute Map.has_key?(Map.from_struct(failure), :recipient)
  end
end
