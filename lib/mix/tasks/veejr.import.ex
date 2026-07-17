defmodule Mix.Tasks.Veejr.Import do
  @shortdoc "Imports a veejr account export zip into this instance"

  @moduledoc """
  Restores an account export (downloaded from another veejr instance via
  `/export`) into this instance's database:

      mix veejr.import path/to/veejr-alice-export.zip [--no-reconnect] [--receipt]

  Intended for seeding a fresh personal instance. See `Veejr.Import` for
  exactly what is restored. After importing, request a login link with your
  email and unlock your keys with the same passphrase as before.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [no_reconnect: :boolean, receipt: :boolean])

    if invalid != [] or length(paths) != 1 do
      Mix.raise("Usage: mix veejr.import path/to/export.zip [--no-reconnect] [--receipt]")
    end

    [path] = paths

    zip =
      case File.read(path) do
        {:ok, zip} -> zip
        {:error, reason} -> Mix.raise("Could not read #{path}: #{:file.format_error(reason)}")
      end

    case Veejr.Import.from_zip(zip) do
      {:ok, summary} ->
        Mix.shell().info("""
        Import complete.

          account:        @#{summary.owner} (confirmed — log in with your email)
          envelopes:      #{summary.envelopes} restored
          ghost contacts: #{summary.ghost_contacts} (senders of your received messages)
          attachments:    #{summary.blobs} blobs restored
        """)

        owner_admin = Veejr.Accounts.instance_admin?(summary.owner_user)

        if opts[:receipt] do
          receipt = %{
            owner: summary.owner,
            owner_admin: owner_admin,
            envelopes: summary.envelopes,
            ghost_contacts: summary.ghost_contacts,
            blobs: summary.blobs,
            friends: length(summary.friends)
          }

          encoded = receipt |> Jason.encode!() |> Base.url_encode64(padding: false)
          Mix.shell().info("VEEJR_IMPORT_RECEIPT=#{encoded}")
        end

        if summary.friends != [] and not opts[:no_reconnect] do
          Mix.shell().info(
            "Reconnecting with #{length(summary.friends)} friends over federation:"
          )

          for {handle, result} <-
                Veejr.Import.reconnect_friends(summary.owner_user, summary.friends) do
            Mix.shell().info("  #{handle}: #{describe(result)}")
          end
        end

        Mix.shell().info("\nUnlock your keys at /keys with the same passphrase you used before.")

      {:error, :owner_already_exists} ->
        Mix.raise("An account with that username or email already exists on this instance.")

      {:error, {:unsupported_version, v}} ->
        Mix.raise("This export is format version #{v}, which this instance cannot import.")

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  defp describe(:request_sent), do: "friend request sent — they'll see it on their instance"
  defp describe(:already_friends), do: "already friends"
  defp describe(:already_requested), do: "request already pending"
  defp describe(:unknown_user), do: "their instance doesn't know that username"

  defp describe(:key_changed),
    do: "their pinned key changed — verify with them, then re-add manually"

  defp describe(:unreachable),
    do: "instance unreachable — re-add them later from the Friends page"
end
