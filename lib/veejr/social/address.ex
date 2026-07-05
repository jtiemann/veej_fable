defmodule Veejr.Social.Address do
  @moduledoc """
  Federation-ready addressing: `username` or `username@host`.

  A bare username or one carrying this instance's own host resolves locally.
  Foreign hosts parse successfully but are not yet routable — callers get
  `{:remote, username, host}` and decide how to respond until instance-to-
  instance delivery ships.
  """

  @username_re ~r/^[a-z0-9_]{3,30}$/

  @type parsed :: {:local, String.t()} | {:remote, String.t(), String.t()} | {:error, :invalid}

  @spec parse(String.t()) :: parsed
  def parse(input) when is_binary(input) do
    input = input |> String.trim() |> String.trim_leading("@") |> String.downcase()

    case String.split(input, "@", parts: 2) do
      [username] ->
        if Regex.match?(@username_re, username), do: {:local, username}, else: {:error, :invalid}

      [username, host] ->
        cond do
          not Regex.match?(@username_re, username) -> {:error, :invalid}
          host == "" -> {:error, :invalid}
          host == Veejr.instance_host() -> {:local, username}
          true -> {:remote, username, host}
        end
    end
  end

  @doc "The full federated address of a user on this instance."
  def full(%{username: username}), do: "#{username}@#{Veejr.instance_host()}"
end
