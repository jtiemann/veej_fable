defmodule Veejr.Updates do
  @moduledoc """
  Pull-based software updates.

  Every instance is sovereign: it checks its configured upstream's GitHub
  releases, its own administrator decides, and the instance upgrades itself
  (`Veejr.Updates.Upgrader`). Nothing is ever pushed to an instance, and the
  check only happens when the admin page asks for it — no unattended
  phone-home.

  `:update_repo` (config / `VEEJR_UPDATE_REPO`) names the `owner/repo` whose
  releases are authoritative, so forks track their own upstream.
  """

  require Logger

  @cache_key {__MODULE__, :latest_release}
  @cache_ttl_seconds 60 * 60

  @doc "The version this instance is running, from the compiled application."
  def current_version, do: Veejr.version()

  @doc "The checked-out commit, when the deployment is a git worktree."
  def current_sha do
    case git(["rev-parse", "--short", "HEAD"]) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  @doc """
  Whether the deployment's working tree has local modifications. A dirty
  tree means this is someone's development checkout — self-upgrade refuses
  to touch it.
  """
  def dirty_worktree? do
    case git(["status", "--porcelain"]) do
      {:ok, ""} -> false
      {:ok, _} -> true
      # not a git checkout at all — nothing to upgrade in place
      _ -> true
    end
  end

  @doc """
  The newest published release of the configured upstream, cached for an
  hour. Pass `force: true` (the admin's "Check now") to bypass the cache.

  Returns `{:ok, release}`, `{:error, :no_releases}`, or `{:error, reason}`.
  The release map carries `:tag`, `:version`, `:name`, `:notes`, `:url`,
  and `:checked_at`.
  """
  def latest_release(opts \\ []) do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, nil) do
      {result, at} when at + @cache_ttl_seconds > now ->
        if opts[:force], do: fetch_and_cache(), else: result

      _ ->
        fetch_and_cache()
    end
  end

  @doc "Whether `release` is strictly newer than the running version."
  def update_available?({:ok, %{version: version}}) do
    match?({:ok, _}, Version.parse(version)) and
      Version.compare(version, current_version()) == :gt
  end

  def update_available?(_), do: false

  defp fetch_and_cache do
    result = fetch_latest_release()
    :persistent_term.put(@cache_key, {result, System.system_time(:second)})
    result
  end

  defp fetch_latest_release do
    repo = Application.fetch_env!(:veejr, :update_repo)

    options =
      [
        base_url: "https://api.github.com",
        retry: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 10_000,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", "veejr-updater"}
        ]
      ] ++ Application.get_env(:veejr, :updates_req_options, [])

    case Req.get(Req.new(options), url: "/repos/#{repo}/releases/latest") do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag} = body}} ->
        {:ok,
         %{
           tag: tag,
           version: String.trim_leading(tag, "v"),
           name: body["name"] || tag,
           notes: body["body"] || "",
           url: body["html_url"],
           checked_at: DateTime.utc_now(:second)
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_releases}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        Logger.warning("updates: release check failed: #{Exception.message(exception)}")
        {:error, :unreachable}
    end
  end

  defp git(args) do
    case System.cmd("git", args, cd: File.cwd!(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    _ -> {:error, :git_unavailable}
  end
end
