defmodule VeejrWeb.InstanceController do
  @moduledoc """
  Public, unauthenticated instance API.

  These two endpoints are the contract other veejr instances (personal or
  community) will rely on for federation: `instance/2` says who this server
  is, and `directory/2` resolves a username to the public key needed to
  encrypt to them. No private data is exposed — public keys are public by
  design, and everything else stays behind authentication.
  """
  use VeejrWeb, :controller

  alias Veejr.Accounts

  def instance(conn, _params) do
    json(conn, %{
      software: "veejr",
      version: Veejr.version(),
      name: Veejr.instance_name(),
      description: Veejr.instance_description(),
      host: Veejr.instance_authority(),
      mode: Veejr.instance_mode(),
      registration_open: Veejr.registration_open?(),
      public_key: Veejr.Federation.Identity.signing_public_key()
    })
  end

  def directory(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      %{public_key: public_key} = user when is_binary(public_key) ->
        json(conn, %{
          username: user.username,
          display_name: user.display_name,
          public_key: public_key,
          host: Veejr.instance_authority()
        })

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "unknown user or no published key"})
    end
  end
end
