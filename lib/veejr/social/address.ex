defmodule Veejr.Social.Address do
  @moduledoc """
  Federated addressing: `username` or `username@authority`.

  The authority is a host with an optional port (`veejr.example.com`,
  `localhost:4001`). A bare username or one carrying this instance's own
  authority resolves locally; anything else is a remote address routed over
  federation.
  """

  @username_re ~r/^[a-z0-9_]{3,30}$/
  # host[:port] — permissive on purpose; the directory fetch is the real test.
  @authority_re ~r/^[a-z0-9.-]+(:\d{1,5})?$/

  @type parsed :: {:local, String.t()} | {:remote, String.t(), String.t()} | {:error, :invalid}

  @spec parse(String.t()) :: parsed
  def parse(input) when is_binary(input) do
    input = input |> String.trim() |> String.trim_leading("@") |> String.downcase()

    case String.split(input, "@", parts: 2) do
      [username] ->
        if Regex.match?(@username_re, username), do: {:local, username}, else: {:error, :invalid}

      [username, authority] ->
        cond do
          not Regex.match?(@username_re, username) -> {:error, :invalid}
          not Regex.match?(@authority_re, authority) -> {:error, :invalid}
          authority == Veejr.instance_authority() -> {:local, username}
          true -> {:remote, username, authority}
        end
    end
  end

  @doc """
  The full federated address of a user: local users get this instance's
  authority, remote users carry their home instance's.
  """
  def full(%{username: username, host: nil}), do: "#{username}@#{Veejr.instance_authority()}"
  def full(%{username: username, host: host}), do: "#{username}@#{host}"
  def full(%{username: username}), do: "#{username}@#{Veejr.instance_authority()}"

  @doc "Short display handle: @user locally, @user@host for remote people."
  def handle(%{username: username, host: nil}), do: "@#{username}"
  def handle(%{username: username, host: host}), do: "@#{username}@#{host}"
  def handle(%{username: username}), do: "@#{username}"
end
