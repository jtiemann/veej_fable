defmodule Veejr.Janitor do
  @moduledoc """
  Periodic background cleanup.

  Currently sweeps abandoned attachment uploads (tracked blobs that were
  never linked to a sent batch) once per interval, keeping filesystem I/O
  off the upload request path. Disabled in tests via `:janitor_interval_ms`;
  tests call `Veejr.Messaging.purge_abandoned_blobs/0` directly.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Veejr.Messaging.purge_abandoned_blobs()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    case Application.get_env(:veejr, :janitor_interval_ms, :timer.hours(1)) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :sweep, ms)
      _ -> :ok
    end
  end
end
