defmodule VeejrWeb.ConversationLauncher do
  @moduledoc false

  alias Veejr.Social

  def destination(assigns, params) do
    selection = Map.get(params, "selection", %{})
    conversation_keys = selection_values(selection, "conversation_keys")
    direct_friend_ids = selection_values(selection, "friend_ids")
    group_ids = selection_values(selection, "group_ids")

    conversations =
      Enum.filter(assigns.conversations, &(to_string(&1.key) in conversation_keys))

    valid_friend_ids = MapSet.new(assigns.friends, &to_string(&1.id))
    direct_friend_ids = Enum.filter(direct_friend_ids, &MapSet.member?(valid_friend_ids, &1))
    valid_groups = Enum.filter(assigns.groups, &(to_string(&1.id) in group_ids))

    conversation_friend_ids =
      conversations
      |> Enum.flat_map(&String.split(&1.reply_ids, ",", trim: true))

    group_friend_ids =
      valid_groups
      |> Enum.flat_map(& &1.members)
      |> Enum.map(&to_string(&1.id))

    friend_ids =
      (direct_friend_ids ++ conversation_friend_ids)
      |> Enum.uniq()

    all_friend_ids = Enum.uniq(friend_ids ++ group_friend_ids)
    include_self = Enum.any?(conversations, &(&1.participants == ["notes to yourself"]))

    cond do
      all_friend_ids == [] and not include_self ->
        {:error, "Select at least one conversation, friend, or group."}

      length(conversations) == 1 and direct_friend_ids == [] and valid_groups == [] ->
        {:ok, "/messages?conversation=#{hd(conversations).key}"}

      existing = matching_conversation(assigns, all_friend_ids, include_self) ->
        {:ok, "/messages?conversation=#{existing.key}"}

      true ->
        query =
          URI.encode_query([
            {"friend_ids", Enum.join(friend_ids, ",")},
            {"group_ids", Enum.map_join(valid_groups, ",", & &1.id)},
            {"include_self", to_string(include_self)}
          ])

        {:ok, "/messages?#{query}"}
    end
  end

  defp selection_values(selection, key) do
    case Map.get(selection, key, []) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp matching_conversation(assigns, friend_ids, include_self) do
    participants =
      if friend_ids == [] and include_self do
        ["notes to yourself"]
      else
        friend_id_set = MapSet.new(friend_ids)

        assigns.friends
        |> Enum.filter(&MapSet.member?(friend_id_set, to_string(&1.id)))
        |> Enum.map(&Social.Address.handle/1)
        |> Enum.sort()
      end

    Enum.find(assigns.conversations, &(&1.participants == participants))
  end
end
