defmodule Veejr.Federation.Client do
  @moduledoc """
  Thin HTTP client for instance-to-instance calls.

  Loopback authorities use plain http so two dev instances can talk;
  everything else is https, no exceptions. `:federation_req_options` lets
  tests plug in `Req.Test`.
  """

  def base_url("localhost" <> _ = authority), do: "http://" <> authority
  def base_url("127.0.0.1" <> _ = authority), do: "http://" <> authority
  def base_url(authority), do: "https://" <> authority

  def get_json(authority, path) do
    case Req.get(req(authority), url: path) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  def post_json(authority, path, payload) do
    case Req.post(req(authority), url: path, json: payload) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp req(authority) do
    options =
      [
        base_url: base_url(authority),
        retry: false,
        connect_options: [timeout: 4_000],
        receive_timeout: 8_000
      ] ++ Application.get_env(:veejr, :federation_req_options, [])

    Req.new(options)
  end
end
