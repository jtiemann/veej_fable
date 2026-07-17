defmodule Veejr.AccountMovesTest do
  use Veejr.DataCase, async: false

  import Veejr.AccountsFixtures

  alias Veejr.{AccountMoves, Accounts, Repo}

  setup do
    old_token = Application.get_env(:veejr, :provisioner_token)
    old_dir = Application.get_env(:veejr, :migration_dir)
    dir = Path.join(System.tmp_dir!(), "veejr-moves-#{System.unique_integer([:positive])}")
    Application.put_env(:veejr, :provisioner_token, String.duplicate("t", 48))
    Application.put_env(:veejr, :migration_dir, dir)

    on_exit(fn ->
      Application.put_env(:veejr, :provisioner_token, old_token)
      Application.put_env(:veejr, :migration_dir, old_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "administrator completes a verified two-pass account move" do
    admin = user_fixture(%{username: "admin"})
    member = user_fixture(%{username: "moving_member"})
    web_token = Accounts.generate_user_session_token(member)

    assert {:ok, move} =
             AccountMoves.create(admin, member.id, %{
               "target_host" => "moving.example.com",
               "instance_name" => "Moving Home",
               "instance_mode" => "personal"
             })

    assert move.status == "awaiting_test"
    assert File.regular?(move.export_path)
    assert byte_size(move.export_sha256) == 64

    assert {:ok, test_job} = AccountMoves.claim()
    assert test_job.phase == "test"
    assert {:ok, package_path} = AccountMoves.package_path(move.public_id)
    assert package_path == move.export_path

    assert {:error, :receipt_mismatch} =
             AccountMoves.record_result(move.public_id, success_receipt(move, "wrong", "test"))

    assert {:ok, tested} =
             AccountMoves.record_result(
               move.public_id,
               success_receipt(move, move.export_sha256, "test")
             )

    assert tested.status == "test_verified"

    assert {:ok, %{move: final_move, sessions: sessions}} =
             AccountMoves.approve_cutover(admin, move.id)

    assert final_move.status == "awaiting_final_import"
    assert File.regular?(final_move.export_path)
    assert String.ends_with?(final_move.export_path, "-final.zip")
    assert sessions.web_count == 1
    refute Accounts.get_user_by_session_token(web_token)
    assert Accounts.get_user!(member.id).suspended_at

    assert {:ok, final_job} = AccountMoves.claim()
    assert final_job.phase == "final"
    final_move = Repo.reload!(final_move)

    assert {:ok, verified} =
             AccountMoves.record_result(
               move.public_id,
               success_receipt(final_move, final_move.export_sha256, "final")
             )

    assert verified.status == "target_verified"
    assert verified.verified_at
    assert {:ok, completed} = AccountMoves.finalize(admin, move.id)
    assert completed.status == "finalized"
    assert completed.user_id == nil
    refute Accounts.get_user_by_username(member.username)
    refute File.exists?(final_move.export_path)
  end

  test "only the administrator can move non-admin local members" do
    admin = user_fixture()
    member = user_fixture()
    attrs = %{"target_host" => "new.example.com", "instance_name" => "New site"}

    assert {:error, :unauthorized} = AccountMoves.create(member, member.id, attrs)
    assert {:error, :protected_admin} = AccountMoves.create(admin, admin.id, attrs)

    assert {:ok, _move} = AccountMoves.create(admin, member.id, attrs)
    assert {:error, :move_in_progress} = AccountMoves.create(admin, member.id, attrs)
  end

  test "cancelling after cutover reactivates the source member" do
    admin = user_fixture()
    member = user_fixture()
    attrs = %{"target_host" => "cancel.example.com", "instance_name" => "Cancel test"}
    {:ok, move} = AccountMoves.create(admin, member.id, attrs)
    {:ok, _} = AccountMoves.claim()

    {:ok, _} =
      AccountMoves.record_result(
        move.public_id,
        success_receipt(move, move.export_sha256, "test")
      )

    {:ok, %{move: final_move}} = AccountMoves.approve_cutover(admin, move.id)

    assert Accounts.get_user!(member.id).suspended_at
    assert {:ok, cancelled} = AccountMoves.cancel(admin, final_move.id)
    assert cancelled.status == "cancelled"
    refute Accounts.get_user!(member.id).suspended_at
  end

  defp success_receipt(move, sha, phase) do
    %{
      "phase" => phase,
      "success" => true,
      "receipt" => %{
        "package_sha256" => sha,
        "owner" => move.username,
        "owner_admin" => true,
        "envelopes" => move.expected_envelopes,
        "blobs" => move.expected_blobs,
        "friends" => move.expected_friends
      }
    }
  end
end
