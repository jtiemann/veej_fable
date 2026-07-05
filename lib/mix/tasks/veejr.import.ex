defmodule Mix.Tasks.Veejr.Import do
  @shortdoc "Imports a veejr account export zip into this instance"

  @moduledoc """
  Restores an account export (downloaded from another veejr instance via
  `/export`) into this instance's database:

      mix veejr.import path/to/veejr-alice-export.zip

  Intended for seeding a fresh personal instance. See `Veejr.Import` for
  exactly what is restored. After importing, request a login link with your
  email and unlock your keys with the same passphrase as before.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]) do
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

        Unlock your keys at /keys with the same passphrase you used before.
        """)

      {:error, :owner_already_exists} ->
        Mix.raise("An account with that username or email already exists on this instance.")

      {:error, {:unsupported_version, v}} ->
        Mix.raise("This export is format version #{v}, which this instance cannot import.")

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix veejr.import path/to/export.zip")
end
