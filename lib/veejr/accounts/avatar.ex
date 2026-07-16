defmodule Veejr.Accounts.Avatar do
  @moduledoc false

  @size 512
  @max_bytes 750_000
  @sof_markers [
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF
  ]

  def size, do: @size
  def max_bytes, do: @max_bytes

  def validate(data) when is_binary(data) and byte_size(data) <= @max_bytes do
    case dimensions(data) do
      {:ok, {@size, @size}} -> :ok
      {:ok, _dimensions} -> {:error, :invalid_dimensions}
      :error -> {:error, :invalid_image}
    end
  end

  def validate(data) when is_binary(data), do: {:error, :too_large}
  def validate(_data), do: {:error, :invalid_image}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: scan_segments(rest)
  def dimensions(_data), do: :error

  defp scan_segments(<<0xFF, marker, rest::binary>>)
       when marker in [0x01, 0xD8] or marker in 0xD0..0xD7,
       do: scan_segments(rest)

  defp scan_segments(<<0xFF, 0xFF, rest::binary>>), do: scan_segments(<<0xFF, rest::binary>>)
  defp scan_segments(<<0xFF, marker, _rest::binary>>) when marker in [0xD9, 0xDA], do: :error

  defp scan_segments(<<0xFF, marker, length::16, rest::binary>>)
       when length >= 2 and byte_size(rest) >= length - 2 do
    payload_size = length - 2
    <<payload::binary-size(^payload_size), tail::binary>> = rest

    if marker in @sof_markers do
      case payload do
        <<_precision, height::16, width::16, _::binary>> when width > 0 and height > 0 ->
          {:ok, {width, height}}

        _ ->
          :error
      end
    else
      scan_segments(tail)
    end
  end

  defp scan_segments(_data), do: :error
end
