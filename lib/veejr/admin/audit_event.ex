defmodule Veejr.Admin.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @actions [
    "account.reactivated",
    "account.suspended",
    "invitation.revoked",
    "sessions.revoked"
  ]

  schema "admin_audit_events" do
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :details, :map, default: %{}

    belongs_to :actor, Veejr.Accounts.User, foreign_key: :actor_user_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :target_type, :target_id, :details, :actor_user_id])
    |> validate_required([:action, :target_type, :target_id, :actor_user_id])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:target_type, ["invitation", "user"])
    |> foreign_key_constraint(:actor_user_id)
  end
end
