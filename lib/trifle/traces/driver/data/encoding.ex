defmodule Trifle.Traces.Driver.Data.Encoding do
  @moduledoc false

  @states %{"success" => :success, "warning" => :warning, "error" => :error, "debug" => :debug}
  @types %{"text" => :text, "head" => :head, "raw" => :raw, "media" => :media}

  def pack_entries(entries, gzip?) do
    body = Jason.encode!(entries)
    if gzip?, do: :zlib.gzip(body), else: body
  end

  def unpack_entries(body, gzip?) do
    body
    |> maybe_gunzip(gzip?)
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

  defp maybe_gunzip(body, true), do: :zlib.gunzip(body)
  defp maybe_gunzip(body, false), do: body

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
