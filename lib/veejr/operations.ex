defmodule Veejr.Operations do
  import Ecto.Query, warn: false

  alias Veejr.Operations.Failure
  alias Veejr.Repo

  def record_failure(channel, operation, reason) do
    error =
      case reason do
        reason when is_binary(reason) -> reason
        reason -> inspect(reason, limit: 20, printable_limit: 300)
      end
      |> String.slice(0, 500)

    with {:ok, failure} <-
           Repo.insert(%Failure{
             channel: channel,
             operation: operation,
             error: error
           }) do
      prune_failures()
      {:ok, failure}
    end
  end

  def count_failures(channel) do
    Repo.aggregate(from(f in Failure, where: f.channel == ^channel), :count)
  end

  def list_failures(limit \\ 20) do
    Repo.all(from(f in Failure, order_by: [desc: f.inserted_at, desc: f.id], limit: ^limit))
  end

  defp prune_failures do
    keep_ids = from(f in Failure, order_by: [desc: f.id], limit: 500, select: f.id)
    Repo.delete_all(from(f in Failure, where: f.id not in subquery(keep_ids)))
  end
end
