defmodule Trifle.Traces.Driver.Data.Encoding do
  @moduledoc false

  @states %{"success" => :success, "warning" => :warning, "error" => :error, "debug" => :debug}
  @types %{"text" => :text, "head" => :head, "raw" => :raw, "media" => :media}

  def pack_entries(entries, gzip?) do
    body = Jason.encode!(entries)
    if gzip?, do: :zlib.gzip(body), else: body
  end

  def unpack_entries(body, gzip?, max_inflated_bytes \\ nil) do
    body
    |> maybe_gunzip(gzip?, max_inflated_bytes)
    |> Jason.decode!()
    |> Enum.map(fn entry ->
      %{
        at: entry["at"],
        message: entry["message"],
        state: Map.get(@states, entry["state"], entry["state"]),
        type: Map.get(@types, entry["type"], entry["type"]),
        level: entry["level"]
      }
      |> maybe_put(:size, entry["size"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  def part_name(part, gzip?), do: "data_#{part}.json#{if gzip?, do: ".gz"}"

  def check_part_size!(size, %{max_part_bytes: max}) when is_integer(max) and size > max do
    raise Trifle.Traces.Error,
      message: "trace part is #{size} bytes, over the #{max} byte limit",
      reason: :too_large
  end

  def check_part_size!(_size, _driver), do: :ok

  # Storage must return exactly the bytes that were asked for.
  def exact!(body, _name, first, last)
      when is_binary(body) and byte_size(body) == last - first + 1,
      do: body

  def exact!(body, name, first, last) do
    got = if is_binary(body), do: "#{byte_size(body)} bytes", else: inspect(body)

    raise Trifle.Traces.Error,
      message: "storage returned #{got} for bytes #{first}-#{last} of #{inspect(name)}"
  end

  def slice!(body, _name, first, last)
      when is_binary(body) and first >= 0 and last >= first and last < byte_size(body),
      do: binary_part(body, first, last - first + 1)

  def slice!(body, name, first, last),
    do: exact!(if(is_binary(body), do: "", else: body), name, first, last)

  defp maybe_gunzip(body, false, _max), do: body
  defp maybe_gunzip(body, true, nil), do: :zlib.gunzip(body)

  # Inflate in bounded steps so a small archive cannot expand without limit.
  defp maybe_gunzip(body, true, max) do
    stream = :zlib.open()

    try do
      :zlib.inflateInit(stream, 31)
      inflate(stream, :zlib.safeInflate(stream, body), max, 0, [])
    after
      :zlib.close(stream)
    end
  end

  defp inflate(stream, {status, output}, max, size, acc) do
    produced = IO.iodata_length(output)
    size = size + produced

    if size > max do
      raise Trifle.Traces.Error,
        message: "trace part inflates beyond the #{max} byte limit",
        reason: :too_large
    end

    case status do
      # All input is consumed; inflateEnd fails unless the archive was complete.
      :finished ->
        end_stream!(stream)
        IO.iodata_to_binary([acc, output])

      :continue ->
        inflate(stream, :zlib.safeInflate(stream, []), max, size, [acc, output])
    end
  end

  defp end_stream!(stream) do
    :zlib.inflateEnd(stream)
  rescue
    ErlangError -> raise Trifle.Traces.Error, message: "trace part is a truncated gzip stream"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
