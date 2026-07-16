defmodule Veejr do
  @moduledoc """
  Veejr keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  The instance mode.

    * `:community` — an open server where anyone can register. This is where
      people get started before they run their own instance.
    * `:personal` — a single-owner instance: registration closes after the
      first account, and all of that account's data lives locally.

  Configured with `config :veejr, instance_mode: ...` or the `VEEJR_MODE`
  environment variable in production.
  """
  def instance_mode do
    Application.get_env(:veejr, :instance_mode, :community)
  end

  def registration_open? do
    case Veejr.InstanceSettings.registration_policy() do
      "open" -> true
      policy when policy in ["invite_only", "closed"] -> false
      "mode_default" -> registration_open_for_mode?()
    end
  end

  defp registration_open_for_mode? do
    case instance_mode() do
      :community -> true
      :personal -> Veejr.Repo.aggregate(Veejr.Accounts.User, :count) == 0
    end
  end

  @doc """
  The host this instance answers as — the `host` part of `username@host`
  addresses. Comes from the endpoint's URL config, so it is already correct
  in prod (PHX_HOST) and dev (localhost).
  """
  def instance_host do
    Application.get_env(:veejr, VeejrWeb.Endpoint)[:url][:host] || "localhost"
  end

  @doc """
  The full authority (`host` or `host:port`) that identifies this instance in
  federation. The port is included when non-standard, so two dev instances on
  localhost:4000 and localhost:4001 are distinct peers.
  """
  def instance_authority do
    uri = URI.parse(VeejrWeb.Endpoint.url())

    if (uri.scheme == "https" and uri.port == 443) or (uri.scheme == "http" and uri.port == 80) do
      uri.host
    else
      "#{uri.host}:#{uri.port}"
    end
  end

  @doc "Human-readable instance name, shown in instance metadata."
  def instance_name do
    Veejr.InstanceSettings.effective_name()
  end

  def instance_description, do: Veejr.InstanceSettings.effective_description()

  def version do
    to_string(Application.spec(:veejr, :vsn))
  end
end
