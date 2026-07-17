defmodule Veejr.Admin.AccountMove do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(awaiting_test testing test_verified test_failed awaiting_final_import provisioning target_verified provision_failed finalized cancelled)

  schema "account_moves" do
    field :public_id, :string
    field :username, :string
    field :target_host, :string
    field :instance_name, :string
    field :instance_mode, :string, default: "personal"
    field :status, :string
    field :export_path, :string
    field :export_sha256, :string
    field :export_size, :integer
    field :expected_envelopes, :integer, default: 0
    field :expected_blobs, :integer, default: 0
    field :expected_friends, :integer, default: 0
    field :receipt, :map
    field :error, :string
    field :cutover_at, :utc_datetime
    field :verified_at, :utc_datetime
    field :finalized_at, :utc_datetime
    field :cancelled_at, :utc_datetime

    belongs_to :user, Veejr.Accounts.User
    belongs_to :initiated_by, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(move, attrs) do
    move
    |> cast(attrs, [
      :public_id,
      :user_id,
      :initiated_by_id,
      :username,
      :target_host,
      :instance_name,
      :instance_mode,
      :status,
      :export_path,
      :export_sha256,
      :export_size,
      :expected_envelopes,
      :expected_blobs,
      :expected_friends
    ])
    |> validate_required([
      :public_id,
      :user_id,
      :initiated_by_id,
      :username,
      :target_host,
      :instance_name,
      :instance_mode,
      :status,
      :export_path,
      :export_sha256,
      :export_size
    ])
    |> update_change(:target_host, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(
      :target_host,
      ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/
    )
    |> validate_length(:instance_name, min: 1, max: 80)
    |> validate_inclusion(:instance_mode, ["personal", "community"])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:public_id)
    |> unique_constraint(:target_host, name: :account_moves_active_target_host_index)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:initiated_by_id)
  end

  def transition_changeset(move, attrs) do
    move
    |> cast(attrs, [
      :status,
      :export_path,
      :export_sha256,
      :export_size,
      :expected_envelopes,
      :expected_blobs,
      :expected_friends,
      :receipt,
      :error,
      :cutover_at,
      :verified_at,
      :finalized_at,
      :cancelled_at
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
