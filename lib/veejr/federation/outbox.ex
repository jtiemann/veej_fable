defmodule Veejr.Federation.Outbox do
  @moduledoc """
  Retry queue for federation deliveries.

  When a peer instance is unreachable, the delivery is parked in
  `outbound_deliveries` and retried with exponential backoff (30s doubling
  up to a 6-hour cap) for up to a week, then dropped. The envelope itself is
  never at risk — it lives on this instance regardless; only the content-free
  notification is being retried.

  A single GenServer ticks every 30 seconds. `process_due/0` is a plain
  function so tests can drive it synchronously (ticking is disabled in the
  test env via `:outbox_tick_ms`).
  """

  use GenServer

  import Ecto.Query, warn: false

  require Logger

  alias Veejr.Federation.Client
  alias Veejr.Repo

  @max_attempts 25
  @base_backoff_seconds 30
  @max_backoff_seconds 6 * 60 * 60
  @batch_size 25

  defmodule Delivery do
    use Ecto.Schema

    schema "outbound_deliveries" do
      field :authority, :string
      field :path, :string
      field :payload, :string
      field :attempts, :integer, default: 0
      field :next_attempt_at, :utc_datetime
      field :last_error, :string

      timestamps(type: :utc_datetime)
    end
  end

  ## API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts a delivery immediately; parks it for retry if the peer is
  unreachable. Returns `:ok` or `{:queued, reason}`.
  """
  def deliver(authority, path, payload) do
    case Client.post_json(authority, path, payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        enqueue(authority, path, payload, reason)
        {:queued, reason}
    end
  end

  @doc "Processes all due deliveries once. Returns `{succeeded, failed}` counts."
  def process_due do
    now = DateTime.utc_now(:second)

    deliveries =
      from(d in Delivery,
        where: d.next_attempt_at <= ^now,
        order_by: [asc: d.next_attempt_at],
        limit: @batch_size
      )
      |> Repo.all()

    results = Enum.map(deliveries, &attempt/1)
    {Enum.count(results, &(&1 == :ok)), Enum.count(results, &(&1 != :ok))}
  end

  def pending_count, do: Repo.aggregate(Delivery, :count)

  ## GenServer

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    process_due()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    case Application.get_env(:veejr, :outbox_tick_ms, 30_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :tick, ms)
      _ -> :ok
    end
  end

  ## Internals

  defp enqueue(authority, path, payload, reason) do
    Repo.insert!(%Delivery{
      authority: authority,
      path: path,
      payload: Jason.encode!(payload),
      attempts: 1,
      next_attempt_at: next_attempt(1),
      last_error: inspect(reason)
    })
  end

  defp attempt(%Delivery{} = delivery) do
    case Client.post_json(delivery.authority, delivery.path, Jason.decode!(delivery.payload)) do
      {:ok, _} ->
        Repo.delete(delivery)
        :ok

      {:error, {:http, status}} when status in [400, 403, 404, 409, 422] ->
        # The peer answered and said no — retrying identical bytes won't help.
        Logger.warning(
          "outbox: dropping delivery to #{delivery.authority}#{delivery.path}: peer rejected with #{status}"
        )

        Repo.delete(delivery)
        :rejected

      {:error, reason} ->
        attempts = delivery.attempts + 1

        if attempts >= @max_attempts do
          Logger.warning(
            "outbox: giving up on delivery to #{delivery.authority}#{delivery.path} after #{attempts} attempts"
          )

          Repo.delete(delivery)
          :gave_up
        else
          delivery
          |> Ecto.Changeset.change(
            attempts: attempts,
            next_attempt_at: next_attempt(attempts),
            last_error: inspect(reason)
          )
          |> Repo.update()

          :retry_later
        end
    end
  end

  defp next_attempt(attempts) do
    backoff = min(@base_backoff_seconds * Integer.pow(2, attempts - 1), @max_backoff_seconds)
    DateTime.add(DateTime.utc_now(:second), backoff, :second)
  end
end
