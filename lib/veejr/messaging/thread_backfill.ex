defmodule Veejr.Messaging.ThreadBackfill do
  @moduledoc """
  One-time backfill for `envelopes.thread_key` and `envelopes.participants`,
  invoked by the migration that adds those columns.

  Replays the historical in-memory conversation grouping: a received copy
  threads by its sender's handle, a self-copy threads by the batch's other
  recipient handles (or the notes-to-yourself sentinel), and existing
  conversation archives claim their envelopes under the archive's instance
  key. Legacy archive rows whose conversation key still equals the
  participant key are migrated to a distinct instance key so post-archive
  messages cannot collide with the archived thread.

  Uses schemaless queries only, so it remains valid as the Ecto schemas
  evolve after this migration.
  """

  import Ecto.Query

  @self_thread ["notes to yourself"]
  @chunk 500

  def run(repo) do
    backfill_thread_fields(repo)
    apply_archive_claims(repo)
    :ok
  end

  defp backfill_thread_fields(repo) do
    rows =
      repo.all(
        from(e in "envelopes",
          join: s in "users",
          on: s.id == e.sender_id,
          join: r in "users",
          on: r.id == e.recipient_id,
          select: %{
            id: e.id,
            batch_id: e.batch_id,
            sender_id: e.sender_id,
            recipient_id: e.recipient_id,
            sender_username: s.username,
            sender_host: s.host,
            recipient_username: r.username,
            recipient_host: r.host
          }
        )
      )

    # Handles of everyone besides the sender, per owned batch — what the
    # sender's self-copy threads under.
    batch_others =
      rows
      |> Enum.group_by(&{&1.batch_id, &1.sender_id})
      |> Map.new(fn {key, group} ->
        handles =
          group
          |> Enum.reject(&(&1.recipient_id == &1.sender_id))
          |> Enum.map(&handle(&1.recipient_username, &1.recipient_host))
          |> Enum.sort()

        {key, handles}
      end)

    rows
    |> Enum.map(fn row ->
      participants =
        if row.sender_id == row.recipient_id do
          case batch_others[{row.batch_id, row.sender_id}] do
            [] -> @self_thread
            handles -> handles
          end
        else
          [handle(row.sender_username, row.sender_host)]
        end

      {row.id, participants}
    end)
    |> Enum.group_by(fn {_id, participants} -> participants end, fn {id, _} -> id end)
    |> Enum.each(fn {participants, ids} ->
      key = Veejr.Messaging.conversation_key(participants)
      json = Jason.encode!(participants)

      for chunk <- Enum.chunk_every(ids, @chunk) do
        repo.update_all(from(e in "envelopes", where: e.id in ^chunk),
          set: [thread_key: key, participants: json]
        )
      end
    end)
  end

  defp apply_archive_claims(repo) do
    archives =
      repo.all(
        from(a in "conversation_archives",
          order_by: [asc: a.updated_at],
          select: %{
            id: a.id,
            user_id: a.user_id,
            conversation_key: a.conversation_key,
            participant_key: a.participant_key,
            participants: a.participants,
            envelope_ids: a.envelope_ids,
            started_at: type(a.started_at, :utc_datetime),
            updated_at: type(a.updated_at, :utc_datetime)
          }
        )
      )

    Enum.each(archives, fn archive ->
      claimed = claimed_envelopes(repo, archive)
      instance_key = ensure_instance_key(repo, archive, claimed)

      for chunk <- claimed |> Enum.map(& &1.id) |> Enum.chunk_every(@chunk) do
        repo.update_all(from(e in "envelopes", where: e.id in ^chunk),
          set: [thread_key: instance_key]
        )
      end
    end)
  end

  defp claimed_envelopes(repo, archive) do
    case decode_list(archive.envelope_ids) do
      [] ->
        # Legacy boundary: claim the user's message envelopes with these
        # participants up to the time the archive was recorded.
        repo.all(
          from(e in "envelopes",
            where:
              e.recipient_id == ^archive.user_id and e.kind == "message" and
                e.participants == ^archive.participants and
                e.inserted_at <= ^archive.updated_at,
            order_by: [asc: e.id],
            select: %{id: e.id, public_id: e.public_id}
          )
        )

      public_ids ->
        repo.all(
          from(e in "envelopes",
            where: e.recipient_id == ^archive.user_id and e.public_id in ^public_ids,
            order_by: [asc: e.id],
            select: %{id: e.id, public_id: e.public_id}
          )
        )
    end
  end

  # Archives created before instance keys reused the participant key; give
  # them a distinct key so the archived thread cannot absorb newer messages.
  defp ensure_instance_key(repo, archive, claimed) do
    if archive.conversation_key != archive.participant_key do
      archive.conversation_key
    else
      seed =
        case claimed do
          [%{public_id: public_id} | _] -> public_id
          [] -> archive.participant_key
        end

      instance_key =
        Veejr.Messaging.archived_conversation_key(
          archive.participant_key,
          archive.started_at,
          [seed]
        )

      repo.update_all(from(a in "conversation_archives", where: a.id == ^archive.id),
        set: [conversation_key: instance_key]
      )

      instance_key
    end
  end

  defp decode_list(value) do
    case Jason.decode(value || "[]") do
      {:ok, ids} when is_list(ids) -> ids
      _ -> []
    end
  end

  defp handle(username, nil), do: "@#{username}"
  defp handle(username, host), do: "@#{username}@#{host}"
end
