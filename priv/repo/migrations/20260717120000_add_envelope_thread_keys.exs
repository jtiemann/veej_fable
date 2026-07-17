defmodule Veejr.Repo.Migrations.AddEnvelopeThreadKeys do
  use Ecto.Migration

  def up do
    alter table(:envelopes) do
      add :thread_key, :string
      add :participants, :string
    end

    create index(:envelopes, [:recipient_id, :thread_key])

    flush()

    Veejr.Messaging.ThreadBackfill.run(repo())
  end

  def down do
    drop index(:envelopes, [:recipient_id, :thread_key])

    alter table(:envelopes) do
      remove :thread_key
      remove :participants
    end
  end
end
