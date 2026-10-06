defmodule Trifle.Traces.MongoQueryTest do
  use ExUnit.Case, async: true

  alias Trifle.Traces.{Driver.Index.Mongo, Driver.Index.Query, TraceRecord}

  test "BSON sort fields match the chronological index and cursor order" do
    {_filter, options} = Mongo.search_query([])
    sort = options |> Keyword.fetch!(:sort) |> BSON.encode() |> IO.iodata_to_binary()
    {time_offset, _} = :binary.match(sort, "first_at" <> <<0>>)
    {reference_offset, _} = :binary.match(sort, "_id" <> <<0>>)

    assert time_offset < reference_offset
    assert options[:limit] == 20
  end

  test "first page uses the time range and equality filters without an offset" do
    from = ~U[2026-10-06 00:00:00.000Z]
    to = ~U[2026-10-07 00:00:00.000Z]

    {filter, options} =
      Mongo.search_query(
        from: from,
        to: to,
        segment: "jobs/App.Worker",
        state: :warning,
        tags: %{any: ["default"], all: ["scheduled"]},
        duration_min: 200,
        limit: 10
      )

    assert filter == %{
             "first_at" => %{"$gte" => from, "$lt" => to},
             "segments" => "jobs/App.Worker",
             "state" => "warning",
             "tags" => %{"$in" => ["default"], "$all" => ["scheduled"]},
             "duration" => %{"$gte" => 200}
           }

    assert options[:limit] == 10
    refute Keyword.has_key?(options, :skip)
  end

  test "next page keeps time bounds and seeks by time before the reference" do
    from = ~U[2026-10-06 00:00:00.000Z]
    to = ~U[2026-10-07 00:00:00.000Z]
    at = ~U[2026-10-06 12:30:00.123000Z]
    reference = "68e3bfc80000000000000002"
    record = %TraceRecord{key: "jobs/App.Worker", reference: reference, first_at: at}
    cursor = Query.encode_cursor(record)
    {:ok, id} = BSON.ObjectId.decode(reference)

    {filter, options} = Mongo.search_query(from: from, to: to, cursor: cursor)

    assert filter["first_at"] == %{"$gte" => from, "$lt" => to, "$lte" => at}

    assert filter["$or"] == [
             %{"first_at" => %{"$lt" => at}},
             %{"first_at" => at, "_id" => %{"$lt" => id}}
           ]

    assert options[:limit] == 20
    refute Keyword.has_key?(options, :skip)
  end

  test "cursor bounds the index scan without an explicit time range" do
    at = ~U[2026-10-06 12:30:00.123000Z]

    cursor =
      Query.encode_cursor(%TraceRecord{
        key: "jobs/App.Worker",
        reference: "68e3bfc80000000000000002",
        first_at: at
      })

    {filter, _options} = Mongo.search_query(cursor: cursor)

    assert filter["first_at"] == %{"$lte" => at}
    assert length(filter["$or"]) == 2
  end

  test "cursor preserves an exclusive time bound earlier than the cursor" do
    to = ~U[2026-10-06 10:00:00.000Z]
    at = ~U[2026-10-06 12:30:00.123000Z]

    cursor =
      Query.encode_cursor(%TraceRecord{
        key: "jobs/App.Worker",
        reference: "68e3bfc80000000000000002",
        first_at: at
      })

    {filter, _options} = Mongo.search_query(to: to, cursor: cursor)

    assert filter["first_at"] == %{"$lt" => to, "$lte" => at}
  end
end
