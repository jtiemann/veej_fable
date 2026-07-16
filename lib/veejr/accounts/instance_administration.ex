defmodule Veejr.Accounts.InstanceAdministration do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "instance_administration" do
    belongs_to :admin_user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
