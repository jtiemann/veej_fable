defmodule Veejr.Updates.Upgrader do
  @moduledoc """
  In-place self-upgrade for the source-mounted deployment.

  The running container carries the full build toolchain and the repository
  is mounted read-write, so the instance can upgrade itself while the old
  code keeps serving:

    1. record the current commit as last-known-good and take an online
       SQLite backup (`VACUUM INTO`, gitignored `*.db` name)
    2. `git fetch` + checkout of the release tag
    3. `mix deps.get` / `mix assets.deploy` / `mix compile --force`
    4. only if every step succeeded, stop the VM — the container restart
       policy boots the new build, which migrates itself at startup
       (`:auto_migrate`)

  Any failed step checks the previous commit back out, best-effort
  recompiles it, and records an operational failure for the admin page.
  The running application is never touched until the new build is proven
  to compile.
  """

  require Logger

  @lock_key {__MODULE__, :running}

  @doc """
  Starts the upgrade to `tag` in a supervised task. Returns `:ok` when the
  upgrade began, `{:error, reason}` when refused. Refusals: another upgrade
  already running, or a dirty working tree (a development checkout).
  """
  def start(tag) when is_binary(tag) do
    cond do
      running?() ->
        {:error, :already_running}

      Veejr.Updates.dirty_worktree?() ->
        {:error, :dirty_worktree}

      true ->
        :persistent_term.put(@lock_key, true)

        Task.Supervisor.start_child(Veejr.TaskSupervisor, fn -> run(tag) end)
        :ok
    end
  end

  @doc "Whether an upgrade is currently in progress."
  def running?, do: :persistent_term.get(@lock_key, false)

  defp run(tag) do
    last_good = rev_parse!()
    Logger.info("upgrade: starting #{last_good} -> #{tag}")

    backup_database!()

    steps = [
      {"git fetch", "git", ["fetch", "--tags", "origin"]},
      {"git checkout", "git", ["-c", "advice.detachedHead=false", "checkout", tag]},
      {"hex", "mix", ["local.hex", "--force"]},
      {"deps", "mix", ["deps.get"]},
      {"assets", "mix", ["assets.deploy"]},
      {"compile", "mix", ["compile", "--force"]}
    ]

    case run_steps(steps) do
      :ok ->
        Logger.info("upgrade: #{tag} built successfully — restarting")
        # The container restart policy brings the new build up; it migrates
        # itself at boot. Stopping is the commit point. The exit code must be
        # non-zero: `on-failure` restart policies ignore clean exits and would
        # leave the instance down after a successful upgrade.
        System.stop(1)

      {:error, step, output} ->
        Logger.error("upgrade: #{step} failed, rolling back to #{last_good}")
        rollback(last_good)

        Veejr.Operations.record_failure(
          "upgrade",
          step,
          "upgrade to #{tag} failed at #{step}: #{String.slice(output, 0, 1500)}"
        )

        :persistent_term.put(@lock_key, false)
    end
  rescue
    error ->
      Logger.error("upgrade: crashed: #{Exception.message(error)}")
      Veejr.Operations.record_failure("upgrade", "run", Exception.message(error))
      :persistent_term.put(@lock_key, false)
  end

  defp run_steps([]), do: :ok

  defp run_steps([{name, cmd, args} | rest]) do
    case System.cmd(cmd, args, cd: File.cwd!(), stderr_to_stdout: true) do
      {_output, 0} -> run_steps(rest)
      {output, _status} -> {:error, name, output}
    end
  end

  defp rollback(last_good) do
    {_, 0} = System.cmd("git", ["checkout", last_good], cd: File.cwd!(), stderr_to_stdout: true)
    # Best effort: leave _build matching the running code again.
    System.cmd("mix", ["compile", "--force"], cd: File.cwd!(), stderr_to_stdout: true)
  rescue
    error -> Logger.error("upgrade: rollback failed: #{Exception.message(error)}")
  end

  defp rev_parse! do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: File.cwd!())
    String.trim(sha)
  end

  # Consistent online copy next to the live database. The `.db` suffix keeps
  # it inside the existing gitignore patterns, so the worktree stays clean.
  defp backup_database! do
    database = Veejr.Repo.config()[:database]
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    backup = String.replace_suffix(database, ".db", "") <> "-preupgrade-#{stamp}.db"

    # VACUUM INTO does not accept bound parameters; the path comes from this
    # instance's own Repo config, never from user input.
    unless String.contains?(backup, "'"), do: Veejr.Repo.query!("VACUUM INTO '#{backup}'")
    Logger.info("upgrade: database backed up to #{backup}")
  end
end
