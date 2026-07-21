defmodule Veejr.Repo.Migrations.AddDedupVersionToEnvelopes do
  use Ecto.Migration

  def change do
    # Opaque content fingerprint for an imported self-note. Lets a re-import
    # detect which notes changed (update) vs are unchanged (skip). NULL for
    # non-imported envelopes and for notes imported before this column existed.
    alter table(:envelopes) do
      add :dedup_version, :string
    end
  end
end
