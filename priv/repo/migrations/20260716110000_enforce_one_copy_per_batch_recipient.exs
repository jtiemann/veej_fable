defmodule Veejr.Repo.Migrations.EnforceOneCopyPerBatchRecipient do
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM envelopes
    WHERE id NOT IN (
      SELECT MIN(id)
      FROM envelopes
      GROUP BY batch_id, recipient_id
    )
    """

    create unique_index(:envelopes, [:batch_id, :recipient_id])
  end

  def down do
    drop unique_index(:envelopes, [:batch_id, :recipient_id])
  end
end
