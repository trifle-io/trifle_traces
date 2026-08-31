defmodule Trifle.Traces.Driver.Index.Query do
  @moduledoc false

  alias Trifle.Traces.TraceRecord

  @groups [:any, :all]

  def limit(filters) do
    case Keyword.get(filters, :limit, 20) do
      limit when is_integer(limit) and limit > 0 ->
        limit

      limit ->
        raise ArgumentError,
              "trace search limit must be a positive integer, got: #{inspect(limit)}"
    end
  end

  def normalize_tags(nil), do: %{any: [], all: []}

  def normalize_tags(tags) when is_map(tags) do
    unknown = Enum.map(Map.keys(tags), &to_string/1) -- Enum.map(@groups, &to_string/1)

    if unknown != [] do
      raise ArgumentError, "unknown tags groups: #{Enum.join(unknown, ", ")}"
    end

    Map.new(@groups, fn group ->
      value = Map.get(tags, group, Map.get(tags, to_string(group)))

      unless is_nil(value) or is_list(value) do
        raise ArgumentError, "tags[:#{group}] must be a list"
      end

      {group, value |> List.wrap() |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    end)
  end

  def normalize_tags(_),
    do: raise(ArgumentError, "tags must be a map with :any and/or :all lists")

  def encode_cursor(%TraceRecord{} = record) do
    {microseconds, _precision} = record.first_at.microsecond
    nanoseconds = microseconds * 1_000
    payload = [DateTime.to_unix(record.first_at), nanoseconds, to_string(record.reference)]
    payload |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  def decode_cursor(nil), do: nil

  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [seconds, nanoseconds, reference]}
         when is_integer(seconds) and is_integer(nanoseconds) and is_binary(reference) <-
           Jason.decode(json),
         {:ok, datetime} <-
           DateTime.from_unix(seconds * 1_000_000 + div(nanoseconds, 1_000), :microsecond) do
      %{first_at: datetime, reference: reference}
    else
      _ -> raise ArgumentError, "invalid trace search cursor"
    end
  end

  def decode_cursor(_), do: raise(ArgumentError, "invalid trace search cursor")

  def matches?(%TraceRecord{} = record, filters) do
    tags = normalize_tags(Keyword.get(filters, :tags))

    segment_matches?(record, Keyword.get(filters, :segment)) and
      tags_match?(record, tags) and
      state_matches?(record, Keyword.get(filters, :state)) and
      time_matches?(record, Keyword.get(filters, :from), Keyword.get(filters, :to)) and
      duration_matches?(record, Keyword.get(filters, :duration_min))
  end

  def after_cursor?(_record, nil), do: true

  def after_cursor?(record, position) do
    case DateTime.compare(record.first_at, position.first_at) do
      :lt -> true
      :eq -> record.reference < position.reference
      :gt -> false
    end
  end

  def sort(records) do
    Enum.sort(records, fn left, right ->
      case DateTime.compare(left.first_at, right.first_at) do
        :gt -> true
        :lt -> false
        :eq -> left.reference >= right.reference
      end
    end)
  end

  defp segment_matches?(_record, nil), do: true
  defp segment_matches?(record, segment), do: segment in TraceRecord.segments(record)

  defp tags_match?(record, tags) do
    (tags.any == [] or Enum.any?(tags.any, &(&1 in record.tags))) and
      (tags.all == [] or Enum.all?(tags.all, &(&1 in record.tags)))
  end

  defp state_matches?(_record, nil), do: true
  defp state_matches?(record, state), do: to_string(record.state) == to_string(state)

  defp time_matches?(record, from, to) do
    (is_nil(from) or DateTime.compare(record.first_at, from) in [:eq, :gt]) and
      (is_nil(to) or DateTime.compare(record.first_at, to) == :lt)
  end

  defp duration_matches?(_record, nil), do: true
  defp duration_matches?(record, minimum), do: record.duration >= minimum
end
