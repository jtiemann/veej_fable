defmodule Veejr.Push.Outbox do
  @moduledoc false
  use GenServer

  @interval :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    send(self(), :deliver)
    {:ok, %{}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :deliver, @interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:deliver, state) do
    Veejr.Push.deliver_due()
    Process.send_after(self(), :deliver, @interval)
    {:noreply, state}
  end
end
