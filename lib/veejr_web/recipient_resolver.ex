defmodule VeejrWeb.RecipientResolver do
  @moduledoc """
  Expands a composer's friend/group selection into concrete recipients with
  public keys, so the browser can encrypt to each of them.

  Only the caller's accepted friends (directly or via their own groups) can
  ever be resolved; group ids belonging to other users simply don't match.
  """

  alias Veejr.Social

  def resolve(user, params) do
    friend_ids = Map.get(params, "friend_ids", [])
    group_ids = Map.get(params, "group_ids", [])

    friend_map = Map.new(Social.list_friends(user), &{to_string(&1.id), &1})
    chosen = friend_ids |> Enum.map(&friend_map[&1]) |> Enum.reject(&is_nil/1)

    from_groups =
      Enum.flat_map(group_ids, fn gid ->
        case Social.group_members(user, gid) do
          members when is_list(members) -> members
          _ -> []
        end
      end)

    all =
      (chosen ++ from_groups)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&(&1.id == user.id))

    {with_keys, without_keys} = Enum.split_with(all, & &1.public_key)

    %{
      recipients:
        Enum.map(
          with_keys,
          &%{
            id: &1.id,
            username: &1.username,
            handle: Veejr.Social.Address.handle(&1),
            public_key: &1.public_key
          }
        ),
      missing_keys: Enum.map(without_keys, & &1.username)
    }
  end
end
