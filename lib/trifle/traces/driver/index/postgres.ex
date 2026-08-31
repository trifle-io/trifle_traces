if Code.ensure_loaded?(Postgrex) do
  defmodule Trifle.Traces.Driver.Index.Postgres do
    @moduledoc """
    PostgreSQL trace metadata index shared with Trifle::Traces for Ruby.

    The queryable may be a Postgrex connection or an Ecto Repo module exposing
    `query!/3`, such as `Trifle.Repo`. Postgrex remains an optional dependency.
    """

    @behaviour Trifle.Traces.Driver.Index

    alias Trifle.Traces.{Driver.Index.Query, TraceRecord}

    defstruct [:queryable, table_name: "trifle_traces"]

    def new(queryable, options \\ []) do
      %__MODULE__{
        queryable: queryable,
        table_name: options |> Keyword.get(:table_name, "trifle_traces") |> validate_table_name!()
      }
    end

    def setup!(queryable, options \\ []) do
      table_name = options |> Keyword.get(:table_name, "trifle_traces") |> validate_table_name!()

      statements = [
        """
        CREATE TABLE IF NOT EXISTS #{table_name} (
          reference TEXT PRIMARY KEY,
          key TEXT NOT NULL,
          segments JSONB NOT NULL DEFAULT '[]'::jsonb,
          state VARCHAR(32) NOT NULL,
          tags JSONB NOT NULL DEFAULT '[]'::jsonb,
          meta JSONB,
          context JSONB NOT NULL DEFAULT '{}'::jsonb,
          duration BIGINT NOT NULL DEFAULT 0,
          counters JSONB NOT NULL DEFAULT '{}'::jsonb,
          length BIGINT NOT NULL DEFAULT 0,
          parts INTEGER NOT NULL DEFAULT 0,
          first_at TIMESTAMPTZ NOT NULL,
          last_at TIMESTAMPTZ NOT NULL,
          retention INTEGER NOT NULL,
          expires_at TIMESTAMPTZ NOT NULL,
          bucket_id INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS #{table_name}_segments_gin " <>
          "ON #{table_name} USING GIN (segments)",
        "CREATE INDEX IF NOT EXISTS #{table_name}_tags_gin " <>
          "ON #{table_name} USING GIN (tags)",
        "CREATE INDEX IF NOT EXISTS #{table_name}_state_started " <>
          "ON #{table_name} (state, first_at DESC, reference DESC)",
        "CREATE INDEX IF NOT EXISTS #{table_name}_started " <>
          "ON #{table_name} (first_at DESC, reference DESC)",
        "CREATE INDEX IF NOT EXISTS #{table_name}_duration_started " <>
          "ON #{table_name} (duration, first_at DESC, reference DESC)",
        "CREATE INDEX IF NOT EXISTS #{table_name}_expires_at " <>
          "ON #{table_name} (expires_at)"
      ]

      Enum.each(statements, &query!(queryable, &1, []))
      :ok
    end

    def cleanup!(queryable_or_driver, options \\ [])

    def cleanup!(%__MODULE__{} = driver, options) do
      cleanup!(driver.queryable, Keyword.put(options, :table_name, driver.table_name))
    end

    def cleanup!(queryable, options) do
      table_name = options |> Keyword.get(:table_name, "trifle_traces") |> validate_table_name!()
      before = Keyword.get(options, :before, DateTime.utc_now())
      result = query!(queryable, "DELETE FROM #{table_name} WHERE expires_at <= $1", [before])
      result.num_rows
    end

    @impl true
    def generate_reference(_driver), do: Trifle.Traces.Ref.generate()

    @impl true
    def capabilities(_driver), do: %{update: true, delete: true, search: true, ttl: :cleanup}

    @impl true
    def create(driver, record) do
      query!(
        driver.queryable,
        """
        INSERT INTO #{driver.table_name} (
          reference, key, segments, state, tags, meta, context,
          duration, counters, length, parts, first_at, last_at,
          retention, expires_at, bucket_id
        ) VALUES (
          $1, $2, $3::jsonb, $4, $5::jsonb, $6::jsonb, $7::jsonb,
          $8, $9::jsonb, $10, $11, $12, $13, $14, $15, $16
        )
        """,
        create_params(record)
      )

      record.reference
    end

    @impl true
    def update(driver, record) do
      query!(
        driver.queryable,
        """
        UPDATE #{driver.table_name}
        SET state = $1, tags = $2::jsonb, context = $3::jsonb,
            duration = $4, counters = $5::jsonb, length = $6,
            parts = $7, last_at = $8, expires_at = $9
        WHERE reference = $10
        """,
        [
          to_string(record.state),
          record.tags,
          record.context || %{},
          record.duration,
          record.counters,
          record.length,
          record.parts,
          record.last_at,
          record.expires_at,
          to_string(record.reference)
        ]
      )

      record.reference
    end

    @impl true
    def delete(driver, reference) do
      query!(driver.queryable, "DELETE FROM #{driver.table_name} WHERE reference = $1", [
        to_string(reference)
      ])

      nil
    end

    @impl true
    def find(driver, reference) do
      result =
        query!(driver.queryable, "SELECT * FROM #{driver.table_name} WHERE reference = $1", [
          to_string(reference)
        ])

      case result.rows do
        [row] -> record_for(row_map(result.columns, row))
        [] -> nil
      end
    end

    @impl true
    def search(driver, filters) do
      limit = Query.limit(filters)
      {query, params} = search_query(driver.table_name, filters, limit)
      result = query!(driver.queryable, query, params)
      traces = Enum.map(result.rows, &record_for(row_map(result.columns, &1)))
      cursor = if length(traces) == limit, do: Query.encode_cursor(List.last(traces))
      %{traces: traces, cursor: cursor}
    end

    defp create_params(record) do
      [
        to_string(record.reference),
        to_string(record.key),
        TraceRecord.segments(record),
        to_string(record.state),
        record.tags || [],
        record.meta,
        record.context || %{},
        record.duration,
        record.counters,
        record.length,
        record.parts,
        record.first_at,
        record.last_at,
        record.retention,
        record.expires_at,
        record.bucket_id
      ]
    end

    defp search_query(table_name, filters, limit) do
      {clauses, params} =
        {[], []}
        |> maybe_json_contains("segments", List.wrap(Keyword.get(filters, :segment)))
        |> add_tag_filters(Query.normalize_tags(Keyword.get(filters, :tags)))
        |> maybe_condition("state =", stringify(Keyword.get(filters, :state)))
        |> maybe_condition("first_at >=", Keyword.get(filters, :from))
        |> maybe_condition("first_at <", Keyword.get(filters, :to))
        |> maybe_condition("duration >=", Keyword.get(filters, :duration_min))
        |> add_cursor(Query.decode_cursor(Keyword.get(filters, :cursor)))

      params = params ++ [limit]
      where = if clauses == [], do: "", else: " WHERE #{Enum.join(clauses, " AND ")}"

      {
        "SELECT * FROM #{table_name}#{where} " <>
          "ORDER BY first_at DESC, reference DESC LIMIT $#{length(params)}",
        params
      }
    end

    defp maybe_json_contains(query, _column, []), do: query

    defp maybe_json_contains({clauses, params}, column, values) do
      params = params ++ [values]
      {clauses ++ ["#{column} @> $#{length(params)}::jsonb"], params}
    end

    defp add_tag_filters(query, %{any: any, all: all}) do
      query
      |> add_any_tags(any)
      |> maybe_json_contains("tags", all)
    end

    defp add_any_tags(query, []), do: query

    defp add_any_tags({clauses, params}, tags) do
      {conditions, params} =
        Enum.map_reduce(tags, params, fn tag, params ->
          params = params ++ [[tag]]
          {"tags @> $#{length(params)}::jsonb", params}
        end)

      {clauses ++ ["(#{Enum.join(conditions, " OR ")})"], params}
    end

    defp maybe_condition(query, _expression, nil), do: query

    defp maybe_condition({clauses, params}, expression, value) do
      params = params ++ [value]
      {clauses ++ ["#{expression} $#{length(params)}"], params}
    end

    defp add_cursor(query, nil), do: query

    defp add_cursor({clauses, params}, position) do
      params = params ++ [position.first_at]
      at_param = length(params)
      params = params ++ [position.reference]
      reference_param = length(params)

      clause =
        "(first_at < $#{at_param} OR " <>
          "(first_at = $#{at_param} AND reference < $#{reference_param}))"

      {clauses ++ [clause], params}
    end

    defp record_for(row) do
      %TraceRecord{
        reference: row["reference"],
        key: row["key"],
        state: known_atom(row["state"], [:running, :success, :warning, :error]),
        tags: decode_json(row["tags"]) || [],
        meta: decode_json(row["meta"]),
        context: decode_json(row["context"]) || %{},
        duration: row["duration"] || 0,
        counters: counters_for(decode_json(row["counters"])),
        length: row["length"] || 0,
        parts: row["parts"] || 0,
        first_at: row["first_at"],
        last_at: row["last_at"],
        retention: row["retention"],
        expires_at: row["expires_at"],
        bucket_id: row["bucket_id"] || 0
      }
    end

    defp counters_for(nil), do: TraceRecord.empty_counters()

    defp counters_for(counters) do
      %{
        states: atomize_counter(field(counters, "states"), [:success, :warning, :error, :debug]),
        types: atomize_counter(field(counters, "types"), [:text, :head, :raw, :media]),
        max_level: field(counters, "max_level") || 0
      }
    end

    defp atomize_counter(values, allowed) do
      Map.new(values || %{}, fn {key, value} -> {known_atom(key, allowed), value} end)
    end

    defp known_atom(value, allowed) do
      Enum.find(allowed, fn candidate -> to_string(candidate) == to_string(value) end) || value
    end

    defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

    defp decode_json(nil), do: nil
    defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
    defp decode_json(value), do: value

    defp field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

    defp stringify(nil), do: nil
    defp stringify(value), do: to_string(value)

    defp validate_table_name!(table_name) do
      value = to_string(table_name)

      if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, value) do
        value
      else
        raise ArgumentError, "invalid PostgreSQL table name: #{inspect(table_name)}"
      end
    end

    defp query!(queryable, statement, params) when is_atom(queryable) do
      if Code.ensure_loaded?(queryable) and function_exported?(queryable, :query!, 3) do
        apply(queryable, :query!, [statement, params, []])
      else
        Postgrex.query!(queryable, statement, params)
      end
    end

    defp query!(queryable, statement, params), do: Postgrex.query!(queryable, statement, params)
  end
end
