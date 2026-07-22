defmodule Veejr.WatchPartiesTest do
  use Veejr.DataCase

  alias Veejr.WatchParties

  test "extracts ids only from supported YouTube URLs" do
    assert {:ok, "dQw4w9WgXcQ"} =
             WatchParties.extract_video_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    assert {:ok, "dQw4w9WgXcQ"} =
             WatchParties.extract_video_id("https://youtu.be/dQw4w9WgXcQ?t=12")

    assert {:ok, "dQw4w9WgXcQ"} = WatchParties.extract_video_id("dQw4w9WgXcQ")

    assert {:error, :invalid_youtube_url} =
             WatchParties.extract_video_id("https://example.com/watch?v=dQw4w9WgXcQ")
  end

  test "only the initiating user can control or end a party" do
    server = start_supervised!({WatchParties, name: unique_server_name()})
    host = %{id: 10, username: "host_user", display_name: "Host"}
    :ok = WatchParties.subscribe()

    assert {:ok, party} = WatchParties.start_party(host, "dQw4w9WgXcQ", server)
    assert_receive {:watch_party_started, ^party}
    assert {:error, :party_active} = WatchParties.start_party(host, "M7lc1UVf-VE", server)
    assert {:error, :not_host} = WatchParties.control(party.public_id, 11, "playing", 2.0, server)
    assert :ok = WatchParties.control(party.public_id, host.id, "playing", 2.0, server)
    assert %{playback: "playing", position: 2.0} = WatchParties.active_party(server)
    assert {:error, :not_host} = WatchParties.end_party(party.public_id, 11, server)
    assert :ok = WatchParties.end_party(party.public_id, host.id, server)
    assert is_nil(WatchParties.active_party(server))
  end

  defp unique_server_name do
    String.to_atom("watch_parties_test_#{System.unique_integer([:positive])}")
  end
end
