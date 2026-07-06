defmodule Veejr.Repo.Migrations.AddCanonicalFriendshipPairIndex do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM friendships
    WHERE id IN (
      SELECT duplicate.id
      FROM friendships AS duplicate
      JOIN friendships AS keeper
        ON min(duplicate.requester_id, duplicate.addressee_id) =
           min(keeper.requester_id, keeper.addressee_id)
       AND max(duplicate.requester_id, duplicate.addressee_id) =
           max(keeper.requester_id, keeper.addressee_id)
       AND duplicate.id != keeper.id
       AND (
         (keeper.status = 'accepted' AND duplicate.status != 'accepted') OR
         (keeper.status = duplicate.status AND keeper.id < duplicate.id)
       )
    )
    """)

    create unique_index(
             :friendships,
             [
               "min(requester_id, addressee_id)",
               "max(requester_id, addressee_id)"
             ],
             name: :friendships_canonical_pair_index
           )
  end

  def down do
    drop index(
           :friendships,
           [
             "min(requester_id, addressee_id)",
             "max(requester_id, addressee_id)"
           ],
           name: :friendships_canonical_pair_index
         )
  end
end
