if Code.ensure_loaded?(Mongo) and Code.ensure_loaded?(BSON.ObjectId) do
  defmodule Trifle.Traces.Driver.Index.Mongo do
    @moduledoc "MongoDB metadata index compatible with Trifle::Traces for Ruby."
    @behaviour Trifle.Traces.Driver.Index

    alias Trifle.Traces.{Driver.Index.Query, TraceRecord}

    defstruct [:connection, collection_name: "trifle_traces"]

    def new(connection, options \\ []) do
      %__MODULE__{
        connection: connection,
        collection_name: Keyword.get(options, :collection_name, "trifle_traces")
      }
    end

    def setup!(connection, options \\ []) do
      collection = Keyword.get(options, :collection_name, "trifle_traces")

      indexes = [
        [key: [segments: 1, first_at: -1, _id: -1], name: "segments_first_at_reference"],
        [key: [tags: 1, first_at: -1, _id: -1], name: "tags_first_at_reference"],
        [key: [state: 1, first_at: -1, _id: -1], name: "state_first_at_reference"],
        [key: [first_at: -1, _id: -1], name: "first_at_reference"],
        [key: [duration: 1, first_at: -1, _id: -1], name: "duration_first_at_reference"],
        [key: [expires_at: 1], name: "expires_at_ttl", expireAfterSeconds: 0]
      ]

      case Mongo.create_indexes(connection, collection, indexes) do
        :ok -> :ok
        {:error, error} -> raise error
      end
    end

    @impl true
    def generate_reference(_driver), do: Mongo.object_id() |> BSON.ObjectId.encode!()

    @impl true
    def capabilities(_driver), do: %{update: true, delete: true, search: true, ttl: :native}

    @impl true
    def create(driver, record) do
      unwrap!(Mongo.insert_one(driver.connection, driver.collection_name, document_for(record)))
      record.reference
    end

    @impl true
    def update(driver, record) do
      unwrap!(
        Mongo.update_one(
          driver.connection,
          driver.collection_name,
          %{"_id" => bson_id(record.reference)},
          %{"$set" => mutable_fields_for(record)}
        )
      )

      record.reference
    end

    @impl true
    def delete(driver, reference) do
      unwrap!(
        Mongo.delete_one(driver.connection, driver.collection_name, %{"_id" => bson_id(reference)})
      )

      nil
    end

    @impl true
    def find(driver, reference) do
      case Mongo.find_one(driver.connection, driver.collection_name, %{
             "_id" => bson_id(reference)
           }) do
        nil -> nil
        {:error, error} -> raise error
        document -> record_for(document)
      end
    end

    @impl true
    def search(driver, filters) do
      limit = Query.limit(filters)
      filter = search_filter(filters)

      documents =
        case Mongo.find(driver.connection, driver.collection_name, filter,
               sort: %{"first_at" => -1, "_id" => -1},
               limit: limit
             ) do
          {:error, error} -> raise error
          cursor -> Enum.to_list(cursor)
        end

      traces = Enum.map(documents, &record_for/1)
      next_cursor = if length(traces) == limit, do: Query.encode_cursor(List.last(traces))
      %{traces: traces, cursor: next_cursor}
    end

    defp document_for(record) do
      Map.merge(mutable_fields_for(record), %{
        "_id" => bson_id(record.reference),
        "key" => record.key,
        "segments" => TraceRecord.segments(record),
        "meta" => if(is_nil(record.meta), do: nil, else: Jason.encode!(record.meta)),
        "first_at" => record.first_at,
        "retention" => record.retention,
        "bucket_id" => record.bucket_id
      })
    end

    defp mutable_fields_for(record) do
      %{
        "state" => to_string(record.state),
        "tags" => record.tags,
        "context" => record.context,
        "duration" => record.duration,
        "counters" => stringify_counters(record.counters),
        "length" => record.length,
        "parts" => record.parts,
        "last_at" => record.last_at,
        "expires_at" => record.expires_at
      }
    end

    defp record_for(document) do
      %TraceRecord{
        reference: document |> field("_id") |> to_string(),
        key: field(document, "key"),
        state: known_atom(field(document, "state"), [:running, :success, :warning, :error]),
        tags: field(document, "tags") || [],
        meta: decode_meta(field(document, "meta")),
        context: field(document, "context") || %{},
        duration: field(document, "duration") || 0,
        counters: counters_for(field(document, "counters")),
        length: field(document, "length") || 0,
        parts: field(document, "parts") || 0,
        first_at: field(document, "first_at"),
        last_at: field(document, "last_at"),
        retention: field(document, "retention"),
        expires_at: field(document, "expires_at"),
        bucket_id: field(document, "bucket_id") || 0
      }
    end

    defp search_filter(filters) do
      tags = Query.normalize_tags(Keyword.get(filters, :tags))
      filter = %{}
      filter = maybe_put(filter, "segments", Keyword.get(filters, :segment))
      filter = maybe_put(filter, "state", stringify(Keyword.get(filters, :state)))

      filter =
        case Keyword.get(filters, :duration_min) do
          nil -> filter
          minimum -> Map.put(filter, "duration", %{"$gte" => minimum})
        end

      filter = add_tags(filter, tags)
      filter = add_time(filter, Keyword.get(filters, :from), Keyword.get(filters, :to))

      case Query.decode_cursor(Keyword.get(filters, :cursor)) do
        nil ->
          filter

        position ->
          Map.put(filter, "$or", [
            %{"first_at" => %{"$lt" => position.first_at}},
            %{"first_at" => position.first_at, "_id" => %{"$lt" => bson_id(position.reference)}}
          ])
      end
    end

    defp add_tags(filter, %{any: [], all: []}), do: filter

    defp add_tags(filter, tags) do
      conditions = %{}
      conditions = if tags.any == [], do: conditions, else: Map.put(conditions, "$in", tags.any)
      conditions = if tags.all == [], do: conditions, else: Map.put(conditions, "$all", tags.all)
      Map.put(filter, "tags", conditions)
    end

    defp add_time(filter, nil, nil), do: filter

    defp add_time(filter, from, to) do
      conditions = %{} |> maybe_put("$gte", from) |> maybe_put("$lt", to)
      Map.put(filter, "first_at", conditions)
    end

    defp bson_id(%BSON.ObjectId{} = id), do: id

    defp bson_id(reference) do
      case BSON.ObjectId.decode(to_string(reference)) do
        {:ok, id} -> id
        :error -> reference
      end
    end

    defp stringify_counters(counters) do
      %{
        "states" => Map.new(counters.states, fn {key, value} -> {to_string(key), value} end),
        "types" => Map.new(counters.types, fn {key, value} -> {to_string(key), value} end),
        "max_level" => counters.max_level
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
      if is_atom(value) and Enum.member?(allowed, value) do
        value
      else
        Enum.find(allowed, fn candidate -> to_string(candidate) == to_string(value) end) || value
      end
    end

    defp decode_meta(nil), do: nil
    defp decode_meta(meta) when is_binary(meta), do: Jason.decode!(meta)
    defp decode_meta(meta), do: meta

    defp field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp stringify(nil), do: nil
    defp stringify(value), do: to_string(value)

    defp unwrap!({:ok, value}), do: value
    defp unwrap!({:error, error}), do: raise(error)
  end
end
