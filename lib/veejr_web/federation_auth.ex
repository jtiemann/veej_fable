defmodule VeejrWeb.FederationAuth do
  @moduledoc """
  Verifies signed federation requests.

  Checks the `x-veejr-authority` / `x-veejr-timestamp` / `x-veejr-signature`
  headers against the sender's pinned instance key (trust-on-first-use via
  `Veejr.Federation.Peers`). The signature covers the request path, the
  timestamp (±5 minutes), and a hash of the raw body. On success the verified
  authority is assigned as `:federation_peer` — handlers must only trust
  origin claims that match it.
  """

  import Plug.Conn

  alias Veejr.Federation.{Identity, Peers}
  alias Veejr.Social.Address

  @max_skew_seconds 300

  def init(opts), do: opts

  def call(conn, _opts) do
    with [authority] <- get_req_header(conn, "x-veejr-authority"),
         [timestamp] <- get_req_header(conn, "x-veejr-timestamp"),
         [signature] <- get_req_header(conn, "x-veejr-signature"),
         {:remote, _, _} <- Address.parse("peer@#{authority}"),
         :ok <- check_timestamp(timestamp),
         {:ok, peer_key} <- Peers.signing_key(authority),
         true <-
           Identity.verify_request(
             peer_key,
             authority,
             conn.request_path,
             timestamp,
             conn.assigns[:raw_body] || "",
             signature
           ) do
      assign(conn, :federation_peer, authority)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "invalid or missing federation signature"})
        |> halt()
    end
  end

  defp check_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        if abs(System.system_time(:second) - seconds) <= @max_skew_seconds,
          do: :ok,
          else: :stale

      _ ->
        :bad
    end
  end
end
