defmodule Veejr.WatchParties do
  @moduledoc """
  Ephemeral, instance-local YouTube watch parties.

  The server retains only the YouTube video id and current playback direction.
  Browsers stream from YouTube directly. One party may be active at a time and
  every control command is authorized against its initiating user.
  """

  use GenServer

  alias Phoenix.PubSub
  alias Veejr.Social.Address

  @global_topic "watch_parties"
  @host_timeout_ms 90_000
  @video_id_re ~r/^[A-Za-z0-9_-]{11}$/

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  def subscribe do
    PubSub.subscribe(Veejr.PubSub, @global_topic)
  end

  def subscribe(public_id) do
    PubSub.subscribe(Veejr.PubSub, party_topic(public_id))
  end

  def active_party(server \\ __MODULE__), do: GenServer.call(server, :active_party)

  def start_party(user, input, server \\ __MODULE__) do
    with {:ok, video_id} <- extract_video_id(input) do
      GenServer.call(server, {:start_party, user, video_id})
    end
  end

  def end_party(public_id, user_id, server \\ __MODULE__) do
    GenServer.call(server, {:end_party, public_id, user_id})
  end

  def control(public_id, user_id, command, position, server \\ __MODULE__) do
    GenServer.call(server, {:control, public_id, user_id, command, position})
  end

  def extract_video_id(input) when is_binary(input) do
    input = String.trim(input)

    cond do
      Regex.match?(@video_id_re, input) -> {:ok, input}
      true -> extract_video_id_from_uri(URI.parse(input))
    end
  end

  def extract_video_id(_input), do: {:error, :invalid_youtube_url}

  @impl true
  def init(_state), do: {:ok, %{party: nil, expiry_ref: nil}}

  @impl true
  def handle_call(:active_party, _from, state), do: {:reply, state.party, state}

  def handle_call({:start_party, _user, _video_id}, _from, %{party: party} = state)
      when not is_nil(party) do
    {:reply, {:error, :party_active}, state}
  end

  def handle_call({:start_party, user, video_id}, _from, state) do
    party = %{
      public_id: Ecto.UUID.generate(),
      host_id: user.id,
      host: user.display_name || Address.handle(user),
      video_id: video_id,
      playback: "paused",
      position: 0.0
    }

    state = schedule_expiry(%{state | party: party})
    PubSub.broadcast(Veejr.PubSub, @global_topic, {:watch_party_started, party})
    {:reply, {:ok, party}, state}
  end

  def handle_call({:end_party, public_id, user_id}, _from, state) do
    case state.party do
      %{public_id: ^public_id, host_id: ^user_id} = party ->
        broadcast_ended(party)
        {:reply, :ok, clear_party(state)}

      %{public_id: ^public_id} ->
        {:reply, {:error, :not_host}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:control, public_id, user_id, command, position}, _from, state) do
    with %{public_id: ^public_id, host_id: ^user_id} = party <- state.party,
         true <- command in ["playing", "paused"],
         {:ok, position} <- valid_position(position) do
      party = %{party | playback: command, position: position}
      PubSub.broadcast(Veejr.PubSub, party_topic(public_id), {:watch_party_control, party})
      {:reply, :ok, schedule_expiry(%{state | party: party})}
    else
      %{public_id: ^public_id} -> {:reply, {:error, :not_host}, state}
      _ -> {:reply, {:error, :invalid_control}, state}
    end
  end

  @impl true
  def handle_info({:expire, public_id}, %{party: %{public_id: public_id} = party} = state) do
    broadcast_ended(party)
    {:noreply, clear_party(state)}
  end

  def handle_info({:expire, _public_id}, state), do: {:noreply, state}

  defp extract_video_id_from_uri(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] do
    host = host && String.downcase(host)

    candidate =
      case host do
        host when host in ["youtu.be", "www.youtu.be"] ->
          first_path_segment(uri.path)

        host when host in ["youtube.com", "www.youtube.com", "m.youtube.com"] ->
          youtube_path_id(uri)

        host when host in ["youtube-nocookie.com", "www.youtube-nocookie.com"] ->
          embedded_id(uri.path)

        _ ->
          nil
      end

    if is_binary(candidate) and Regex.match?(@video_id_re, candidate) do
      {:ok, candidate}
    else
      {:error, :invalid_youtube_url}
    end
  end

  defp extract_video_id_from_uri(_uri), do: {:error, :invalid_youtube_url}

  defp youtube_path_id(%URI{path: "/watch", query: query}) do
    query
    |> then(&(&1 || ""))
    |> URI.decode_query()
    |> Map.get("v")
  end

  defp youtube_path_id(%URI{path: path}), do: embedded_id(path)

  defp embedded_id(path) do
    case String.split(path || "", "/", trim: true) do
      [kind, video_id | _] when kind in ["embed", "shorts", "live"] -> video_id
      _ -> nil
    end
  end

  defp first_path_segment(path), do: path |> String.split("/", trim: true) |> List.first()

  defp valid_position(position) when is_integer(position) and position >= 0 and position < 86_400,
    do: {:ok, position * 1.0}

  defp valid_position(position) when is_float(position) and position >= 0 and position < 86_400,
    do: {:ok, position}

  defp valid_position(_position), do: {:error, :invalid_position}

  defp schedule_expiry(state) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)
    ref = Process.send_after(self(), {:expire, state.party.public_id}, @host_timeout_ms)
    %{state | expiry_ref: ref}
  end

  defp clear_party(state) do
    if state.expiry_ref, do: Process.cancel_timer(state.expiry_ref)
    %{state | party: nil, expiry_ref: nil}
  end

  defp broadcast_ended(party) do
    event = {:watch_party_ended, party.public_id}
    PubSub.broadcast(Veejr.PubSub, @global_topic, event)
    PubSub.broadcast(Veejr.PubSub, party_topic(party.public_id), event)
  end

  defp party_topic(public_id), do: "watch_party:#{public_id}"
end
