defmodule Veejr.AccountMoves do
  @moduledoc "Guarded account migration workflow and provisioner protocol."

  import Ecto.Query, warn: false

  alias Veejr.Accounts.User
  alias Veejr.Admin.{AccountMove, AuditEvent}
  alias Veejr.{Accounts, Admin, Export, Federation, Repo, Social}

  @active_statuses ~w(awaiting_test testing test_verified test_failed awaiting_final_import provisioning target_verified provision_failed)
  @claimable %{"awaiting_test" => "testing", "awaiting_final_import" => "provisioning"}

  def enabled?, do: is_binary(token()) and byte_size(token()) >= 32

  def change_account_move(attrs \\ %{}) do
    AccountMove.create_changeset(%AccountMove{}, attrs)
  end

  def list_account_moves do
    Repo.all(
      from(m in AccountMove, order_by: [desc: m.inserted_at], preload: [:user, :initiated_by])
    )
  end

  def create(%User{} = actor, user_id, attrs) do
    with :ok <- authorize(actor),
         true <- enabled?() || {:error, :provisioner_disabled},
         {:ok, user} <- manageable_user(user_id),
         false <- active_move?(user.id),
         {:ok, artifact} <- build_artifact(user, Ecto.UUID.generate()) do
      public_id = artifact.public_id

      params =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.merge(%{
          "public_id" => public_id,
          "user_id" => user.id,
          "initiated_by_id" => actor.id,
          "username" => user.username,
          "status" => "awaiting_test",
          "export_path" => artifact.path,
          "export_sha256" => artifact.sha256,
          "export_size" => artifact.size,
          "expected_envelopes" => artifact.envelopes,
          "expected_blobs" => artifact.blobs,
          "expected_friends" => artifact.friends
        })

      Repo.transaction(fn ->
        case %AccountMove{} |> AccountMove.create_changeset(params) |> Repo.insert() do
          {:ok, move} ->
            audit!(actor, "account_move.created", move, %{"username" => user.username})
            move

          {:error, changeset} ->
            File.rm(artifact.path)
            Repo.rollback(changeset)
        end
      end)
    else
      true -> {:error, :move_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  def approve_cutover(%User{} = actor, move_id) do
    with :ok <- authorize(actor),
         %AccountMove{status: "test_verified", user: %User{} = user} = move <- get_move(move_id) do
      perform_cutover(actor, move, user)
    else
      nil -> {:error, :not_found}
      %AccountMove{} -> {:error, :invalid_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_cutover(actor, move, user) do
    with {:ok, sessions} <- Admin.suspend_user(actor, user.id) do
      case build_artifact(Repo.reload!(user), move.public_id <> "-final") do
        {:ok, artifact} ->
          File.rm(move.export_path)

          {:ok, updated} =
            move
            |> AccountMove.transition_changeset(%{
              status: "awaiting_final_import",
              export_path: artifact.path,
              export_sha256: artifact.sha256,
              export_size: artifact.size,
              expected_envelopes: artifact.envelopes,
              expected_blobs: artifact.blobs,
              expected_friends: artifact.friends,
              receipt: nil,
              error: nil,
              cutover_at: DateTime.utc_now(:second)
            })
            |> Repo.update()

          audit!(actor, "account_move.cutover_approved", updated, %{"username" => move.username})
          {:ok, %{move: updated, sessions: sessions}}

        {:error, reason} ->
          Admin.reactivate_user(actor, user.id)
          {:error, reason}
      end
    end
  end

  def finalize(%User{} = actor, move_id) do
    with :ok <- authorize(actor),
         %AccountMove{status: "target_verified", user: %User{} = user} = move <- get_move(move_id),
         {:ok, replacement} <- Federation.ensure_remote_user(user.username, move.target_host),
         true <- replacement.public_key == user.public_key || {:error, :key_changed} do
      remote_friend_hosts =
        user
        |> Social.list_friends()
        |> Enum.map(& &1.host)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      result =
        Repo.transaction(fn ->
          with {:ok, _summary} <- Social.relocate_contact(user, replacement),
               {:ok, _user} <- Accounts.delete_user(user) do
            updated =
              move.id
              |> then(&Repo.get!(AccountMove, &1))
              |> AccountMove.transition_changeset(%{
                status: "finalized",
                finalized_at: DateTime.utc_now(:second)
              })
              |> Repo.update!()

            audit!(actor, "account_move.finalized", updated, %{"username" => move.username})
            File.rm(move.export_path)
            updated
          else
            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      with {:ok, _updated} <- result do
        Federation.announce_account_move(user, move.target_host, remote_friend_hosts)
        result
      end
    else
      nil -> {:error, :not_found}
      %AccountMove{} -> {:error, :invalid_state}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel(%User{} = actor, move_id) do
    with :ok <- authorize(actor),
         %AccountMove{} = move <- get_move(move_id),
         true <- move.status in @active_statuses || {:error, :invalid_state} do
      if move.cutover_at && move.user && move.user.suspended_at do
        Admin.reactivate_user(actor, move.user.id)
      end

      {:ok, updated} =
        move
        |> AccountMove.transition_changeset(%{
          status: "cancelled",
          cancelled_at: DateTime.utc_now(:second)
        })
        |> Repo.update()

      File.rm(move.export_path)
      audit!(actor, "account_move.cancelled", updated, %{"username" => move.username})
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def retry(%User{} = actor, move_id) do
    with :ok <- authorize(actor),
         %AccountMove{} = move <- get_move(move_id),
         next when is_binary(next) <- retry_status(move.status) do
      {:ok, updated} =
        move
        |> AccountMove.transition_changeset(%{status: next, error: nil})
        |> Repo.update()

      audit!(actor, "account_move.retried", updated, %{"username" => move.username})
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_state}
      {:error, reason} -> {:error, reason}
    end
  end

  def claim do
    Repo.transaction(fn ->
      case Repo.one(
             from(m in AccountMove,
               where: m.status in ["awaiting_test", "awaiting_final_import"],
               order_by: [asc: m.inserted_at],
               limit: 1
             )
           ) do
        nil ->
          nil

        move ->
          next = Map.fetch!(@claimable, move.status)

          {count, _} =
            Repo.update_all(
              from(m in AccountMove, where: m.id == ^move.id and m.status == ^move.status),
              set: [status: next, updated_at: DateTime.utc_now(:second)]
            )

          if count == 1,
            do: move |> Repo.reload!() |> job_payload(),
            else: Repo.rollback(:already_claimed)
      end
    end)
  end

  def package_path(public_id) do
    case Repo.get_by(AccountMove, public_id: public_id) do
      %AccountMove{status: status, export_path: path}
      when status in ["testing", "provisioning"] ->
        {:ok, path}

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :invalid_state}
    end
  end

  def record_result(public_id, attrs) do
    with %AccountMove{} = move <- Repo.get_by(AccountMove, public_id: public_id),
         :ok <- validate_result_state(move, attrs),
         :ok <- validate_receipt(move, attrs) do
      success = attrs["success"] == true
      next = result_status(move.status, success)

      Repo.transaction(fn ->
        updated =
          move
          |> AccountMove.transition_changeset(%{
            status: next,
            receipt: attrs["receipt"],
            error: if(success, do: nil, else: attrs["error"] || "Provisioner reported failure"),
            verified_at:
              if(next == "target_verified", do: DateTime.utc_now(:second), else: move.verified_at)
          })
          |> Repo.update!()

        actor = Repo.get!(User, move.initiated_by_id)

        action =
          case next do
            "test_verified" -> "account_move.test_verified"
            "target_verified" -> "account_move.target_verified"
            _ -> "account_move.failed"
          end

        audit!(actor, action, updated, %{
          "username" => move.username,
          "status" => next,
          "via" => "provisioner"
        })

        updated
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def secure_token?(candidate) when is_binary(candidate) do
    expected = token()

    is_binary(expected) and byte_size(candidate) == byte_size(expected) and
      Plug.Crypto.secure_compare(candidate, expected)
  end

  def secure_token?(_), do: false

  defp authorize(actor),
    do: if(Accounts.instance_admin?(actor), do: :ok, else: {:error, :unauthorized})

  defp manageable_user(user_id) do
    case Repo.get(User, user_id) do
      %User{host: nil} = user ->
        if Accounts.instance_admin?(user), do: {:error, :protected_admin}, else: {:ok, user}

      _ ->
        {:error, :not_found}
    end
  end

  defp active_move?(user_id),
    do:
      Repo.exists?(
        from(m in AccountMove, where: m.user_id == ^user_id and m.status in ^@active_statuses)
      )

  defp get_move(id), do: AccountMove |> Repo.get(id) |> Repo.preload(:user)
  defp retry_status("test_failed"), do: "awaiting_test"
  defp retry_status("provision_failed"), do: "awaiting_final_import"
  defp retry_status("testing"), do: "awaiting_test"
  defp retry_status("provisioning"), do: "awaiting_final_import"
  defp retry_status(_), do: false

  defp build_artifact(user, public_id) do
    with {:ok, _filename, zip} <- Export.build(user),
         {:ok, files} <- :zip.unzip(zip, [:memory]),
         {_, manifest_json} <-
           Enum.find(files, fn {name, _} -> to_string(name) == "export.json" end),
         {:ok, manifest} <- Jason.decode(manifest_json) do
      dir = Application.fetch_env!(:veejr, :migration_dir)
      File.mkdir_p!(dir)
      path = Path.join(dir, public_id <> ".zip")
      File.write!(path, zip)

      {:ok,
       %{
         public_id: public_id,
         path: path,
         sha256: Base.encode16(:crypto.hash(:sha256, zip), case: :lower),
         size: byte_size(zip),
         envelopes: length(manifest["envelopes"] || []),
         blobs:
           Enum.count(files, fn {name, _} -> String.starts_with?(to_string(name), "blobs/") end),
         friends: length(manifest["friends"] || [])
       }}
    else
      _ -> {:error, :export_failed}
    end
  end

  defp job_payload(move) do
    phase = if move.status == "testing", do: "test", else: "final"

    %{
      id: move.public_id,
      phase: phase,
      username: move.username,
      target_host: move.target_host,
      instance_name: move.instance_name,
      instance_mode: move.instance_mode,
      package_path: "/api/provisioner/v1/moves/#{move.public_id}/package",
      package_sha256: move.export_sha256,
      expected: %{
        envelopes: move.expected_envelopes,
        blobs: move.expected_blobs,
        friends: move.expected_friends
      }
    }
  end

  defp validate_result_state(%{status: "testing"}, %{"phase" => "test"}), do: :ok
  defp validate_result_state(%{status: "provisioning"}, %{"phase" => "final"}), do: :ok
  defp validate_result_state(_, _), do: {:error, :invalid_state}

  defp validate_receipt(_move, %{"success" => false}), do: :ok

  defp validate_receipt(move, %{"success" => true, "receipt" => receipt}) when is_map(receipt) do
    valid =
      receipt["package_sha256"] == move.export_sha256 and
        receipt["owner"] == move.username and receipt["owner_admin"] == true and
        receipt["envelopes"] == move.expected_envelopes and
        receipt["blobs"] == move.expected_blobs and
        receipt["friends"] == move.expected_friends

    if valid, do: :ok, else: {:error, :receipt_mismatch}
  end

  defp validate_receipt(_, _), do: {:error, :invalid_receipt}

  defp result_status("testing", true), do: "test_verified"
  defp result_status("testing", false), do: "test_failed"
  defp result_status("provisioning", true), do: "target_verified"
  defp result_status("provisioning", false), do: "provision_failed"

  defp audit!(actor, action, move, details) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      action: action,
      target_type: "account_move",
      target_id: move.id,
      details: Map.put(details, "target_host", move.target_host),
      actor_user_id: actor.id
    })
    |> Repo.insert!()
  end

  defp token, do: Application.get_env(:veejr, :provisioner_token)
end
