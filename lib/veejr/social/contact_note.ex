defmodule Veejr.Social.ContactNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contact_notes" do
    belongs_to :owner, Veejr.Accounts.User
    belongs_to :contact, Veejr.Accounts.User
    field :body, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(contact_note, attrs) do
    contact_note
    |> cast(attrs, [:owner_id, :contact_id, :body])
    |> validate_required([:owner_id, :contact_id])
    |> validate_length(:body, max: 4_000)
    |> unique_constraint([:owner_id, :contact_id])
    |> check_not_self()
  end

  defp check_not_self(changeset) do
    if get_field(changeset, :owner_id) == get_field(changeset, :contact_id) do
      add_error(changeset, :contact_id, "cannot note yourself as a contact")
    else
      changeset
    end
  end
end
