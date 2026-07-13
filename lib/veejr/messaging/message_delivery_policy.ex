defmodule Veejr.Messaging.MessageDeliveryPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  @subject_types ~w(contact group conversation)
  @acceptances ~w(ask automatic)
  @notifications ~w(normal preview silent)

  schema "message_delivery_policies" do
    belongs_to :user, Veejr.Accounts.User
    field :subject_type, :string
    field :subject_id, :integer
    field :acceptance, :string
    field :notification, :string, default: "normal"

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:acceptance, :notification])
    |> validate_required([:acceptance, :notification])
    |> validate_inclusion(:acceptance, @acceptances)
    |> validate_inclusion(:notification, @notifications)
    |> unique_constraint([:user_id, :subject_type, :subject_id])
  end

  def subject_types, do: @subject_types
end
