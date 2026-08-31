defmodule Trifle.Traces.QueryTest do
  use ExUnit.Case, async: true

  alias Trifle.Traces.{Driver.Index.Query, TraceRecord}

  test "normalizes tag groups and rejects malformed filters" do
    assert Query.limit([]) == 20
    assert Query.limit(limit: 50) == 50

    assert_raise ArgumentError, "trace search limit must be a positive integer, got: 0", fn ->
      Query.limit(limit: 0)
    end

    assert Query.normalize_tags(%{"any" => ["one", "one", nil], all: ["two"]}) == %{
             any: ["one"],
             all: ["two"]
           }

    assert_raise ArgumentError, "unknown tags groups: none", fn ->
      Query.normalize_tags(%{none: []})
    end

    assert_raise ArgumentError, "tags[:any] must be a list", fn ->
      Query.normalize_tags(%{any: "one"})
    end

    assert_raise ArgumentError, "tags must be a map with :any and/or :all lists", fn ->
      Query.normalize_tags(["one"])
    end
  end

  test "cursor preserves timestamp and reference and rejects invalid values" do
    record = record(first_at: ~U[2026-08-31 12:30:45.123456Z], reference: "reference")
    cursor = Query.encode_cursor(record)

    assert Query.decode_cursor(cursor) == %{
             first_at: ~U[2026-08-31 12:30:45.123456Z],
             reference: "reference"
           }

    assert Query.decode_cursor(nil) == nil

    assert_raise ArgumentError, "invalid trace search cursor", fn ->
      Query.decode_cursor("bad")
    end

    assert_raise ArgumentError, "invalid trace search cursor", fn -> Query.decode_cursor(42) end
  end

  test "matches segments, time bounds, duration, tags, and state" do
    at = ~U[2026-08-31 12:30:45Z]
    record = record(first_at: at, tags: ["tenant:1", "billing"], duration: 1_500)

    assert Query.matches?(record,
             segment: "jobs/import",
             tags: %{any: ["tenant:2", "tenant:1"], all: ["billing"]},
             state: "success",
             from: at,
             to: DateTime.add(at, 1, :second),
             duration_min: 1_000
           )

    refute Query.matches?(record, to: at)
    refute Query.matches?(record, duration_min: 2_000)
    refute Query.matches?(record, state: :error)
  end

  defp record(overrides) do
    defaults = %TraceRecord{
      reference: "reference",
      key: "jobs/import/products",
      state: :success,
      tags: [],
      duration: 0,
      counters: TraceRecord.empty_counters(),
      first_at: ~U[2026-08-31 00:00:00Z],
      last_at: ~U[2026-08-31 00:00:00Z],
      expires_at: ~U[2026-09-07 00:00:00Z]
    }

    struct!(defaults, overrides)
  end
end
