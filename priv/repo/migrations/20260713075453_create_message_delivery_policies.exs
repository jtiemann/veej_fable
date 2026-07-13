defmodule Veejr.Repo.Migrations.CreateMessageDeliveryPolicies do
  use Ecto.Migration

  def change do
    create table(:message_delivery_policies) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :subject_type, :string, null: false
      add :subject_id, :integer, null: false
      add :acceptance, :string, null: false
      add :notification, :string, null: false, default: "normal"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:message_delivery_policies, [:user_id, :subject_type, :subject_id])
    create index(:message_delivery_policies, [:user_id, :subject_type])
  end
end
