defmodule Veejr.Repo.Migrations.AddDedupKeyToEnvelopes do
  use Ecto.Migration

  def change do
    # Opaque, client-computed idempotency token for imported self-notes; NULL for
    # everything else. SQLite treats NULLs as distinct in a unique index, so
    # non-import envelopes never collide.
    alter table(:envelopes) do
      add :dedup_key, :string
    end

    create unique_index(:envelopes, [:recipient_id, :dedup_key])
  end
end
