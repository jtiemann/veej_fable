defmodule Veejr.Calls.IceConfig do
  @moduledoc """
  ICE server configuration handed to browsers for WebRTC calls.

  Defaults to a public STUN server. Operators can override with their own
  STUN and add TURN relays (`VEEJR_STUN_URLS`, `VEEJR_TURN_URLS`,
  `VEEJR_TURN_USERNAME`, `VEEJR_TURN_PASSWORD` in prod) — see OPERATIONS.md
  for running a coturn sidecar. TURN relays only encrypted SRTP, so the
  trust model is unchanged.
  """

  def servers do
    Application.get_env(:veejr, :ice_servers, [%{urls: ["stun:stun.l.google.com:19302"]}])
  end
end
