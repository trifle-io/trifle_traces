defmodule Trifle.Traces.ExternalDriverTest do
  use ExUnit.Case

  alias Trifle.Traces.{Configuration, TraceRecord}
  alias Trifle.Traces.Driver.Data.Memory, as: MemoryData
  alias Trifle.Traces.Driver.Data.S3
  alias Trifle.Traces.Driver.Index.Mongo, as: MongoIndex
  alias Trifle.Traces.Driver.Index.Postgres, as: PostgresIndex

  defmodule RepoProxy do
    def query!(statement, params, _options) do
      Postgrex.query!(Trifle.Traces.PostgresExternalConnection, statement, params)
    end
  end

  @moduletag :integration

  test "Mongo index stores and searches production-shaped records" do
    case System.get_env("MONGO_URL") do
      nil ->
        :ok

      url ->
        {:ok, connection} = Mongo.start_link(url: url)
        collection = "trifle_traces_#{System.unique_integer([:positive])}"
        :ok = MongoIndex.setup!(connection, collection_name: collection)

        config =
          Configuration.new(
            index_driver: MongoIndex.new(connection, collection_name: collection),
            data_driver: MemoryData.new(),
            bump_every: 0,
            context: %{"tenant_id" => 42}
          )

        {:ok, tracer} = Trifle.Traces.start_tracer("jobs/mongo/interop", config: config)
        Trifle.Traces.tag("tenant:42", tracer: tracer)
        Trifle.Traces.trace("stored", tracer: tracer)
        final = Trifle.Traces.wrapup(tracer: tracer)
        record = Trifle.Traces.find(final.reference, config: config)

        assert record.reference == final.reference
        assert record.context == %{"tenant_id" => 42}
        assert record.counters.states.success == record.length

        result =
          Trifle.Traces.search(
            config: config,
            segment: "jobs/mongo",
            tags: %{all: ["tenant:42"]},
            state: :success,
            duration_min: 0
          )

        assert Enum.map(result.traces, & &1.reference) == [final.reference]
        :ok = Mongo.drop_collection(connection, collection)
    end
  end

  test "ExAws S3 adapter round-trips against an S3-compatible endpoint" do
    case System.get_env("S3_ENDPOINT") do
      nil ->
        :ok

      endpoint ->
        uri = URI.parse(endpoint)
        bucket = "trifle-traces-#{System.unique_integer([:positive])}"

        client = [
          access_key_id: System.get_env("S3_ACCESS_KEY", "minioadmin"),
          secret_access_key: System.get_env("S3_SECRET_KEY", "minioadmin"),
          region: "us-east-1",
          scheme: "#{uri.scheme}://",
          host: uri.host,
          port: uri.port
        ]

        {:ok, _} = bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(client)

        assert :ok ==
                 S3.setup!(
                   client: client,
                   buckets: [bucket],
                   retentions: [3, 30],
                   gzip: true
                 )

        driver = S3.new(client: client, buckets: [bucket], gzip: true)
        now = DateTime.utc_now()

        record = %TraceRecord{
          reference: Trifle.Traces.Ref.generate(),
          key: "jobs/s3/interop",
          parts: 1,
          retention: 3,
          first_at: now,
          last_at: now,
          expires_at: DateTime.add(now, 3, :day)
        }

        entries = [%{at: 1_700_000_000, message: "s3", state: :success, type: :text, level: 0}]
        S3.write_part(driver, record, 1, entries)
        S3.write_artifact(driver, record, "report.txt", payload: "artifact")

        assert S3.read(driver, record) == entries
        assert S3.read_artifact(driver, record, "report.txt") == "artifact"
        S3.delete(driver, record)
        {:ok, _} = bucket |> ExAws.S3.delete_bucket() |> ExAws.request(client)
    end
  end

  test "PostgreSQL index supports an Ecto Repo-shaped queryable and cleanup" do
    case System.get_env("POSTGRES_URL") do
      nil ->
        :ok

      url ->
        uri = URI.parse(url)
        [username, password] = String.split(uri.userinfo, ":", parts: 2)

        {:ok, connection} =
          Postgrex.start_link(
            hostname: uri.host,
            port: uri.port,
            username: username,
            password: password,
            database: String.trim_leading(uri.path, "/"),
            name: Trifle.Traces.PostgresExternalConnection
          )

        table = "trifle_traces_#{System.unique_integer([:positive])}"
        :ok = PostgresIndex.setup!(RepoProxy, table_name: table)
        driver = PostgresIndex.new(RepoProxy, table_name: table)

        config =
          Configuration.new(
            index_driver: driver,
            data_driver: MemoryData.new(),
            bump_every: 0,
            context: %{"tenant_id" => 42}
          )

        {:ok, tracer} = Trifle.Traces.start_tracer("jobs/postgres/interop", config: config)
        Trifle.Traces.tag("tenant:42", tracer: tracer)
        Trifle.Traces.trace("stored", tracer: tracer)
        final = Trifle.Traces.wrapup(tracer: tracer)
        record = Trifle.Traces.find(final.reference, config: config)

        assert record.reference == final.reference
        assert record.context == %{"tenant_id" => 42}
        assert record.counters.states.success == record.length

        result =
          Trifle.Traces.search(
            config: config,
            segment: "jobs/postgres",
            tags: %{all: ["tenant:42"]},
            state: :success,
            duration_min: 0
          )

        assert Enum.map(result.traces, & &1.reference) == [final.reference]

        now = DateTime.utc_now()

        Enum.each(
          [
            postgres_record("postgres-page-a", now, :success, ["tenant:1", "batch"], 100),
            postgres_record("postgres-page-b", now, :error, ["tenant:2", "batch"], 200),
            postgres_record("postgres-page-c", now, :error, ["tenant:3"], 300)
          ],
          &PostgresIndex.create(driver, &1)
        )

        combined =
          PostgresIndex.search(driver,
            segment: "jobs/postgres/page",
            tags: %{any: ["tenant:2", "tenant:3"], all: ["batch"]},
            state: :error,
            from: DateTime.add(now, -1, :second),
            to: DateTime.add(now, 1, :second),
            duration_min: 200
          )

        assert Enum.map(combined.traces, & &1.reference) == ["postgres-page-b"]

        first_page = PostgresIndex.search(driver, segment: "jobs/postgres/page", limit: 2)

        second_page =
          PostgresIndex.search(driver,
            segment: "jobs/postgres/page",
            limit: 2,
            cursor: first_page.cursor
          )

        assert Enum.map(first_page.traces ++ second_page.traces, & &1.reference) == [
                 "postgres-page-c",
                 "postgres-page-b",
                 "postgres-page-a"
               ]

        assert PostgresIndex.delete(driver, "postgres-page-b") == nil
        assert PostgresIndex.find(driver, "postgres-page-b") == nil

        expired = %TraceRecord{
          reference: Trifle.Traces.Ref.generate(),
          key: "expired",
          state: :success,
          counters: TraceRecord.empty_counters(),
          first_at: DateTime.add(now, -2, :day),
          last_at: DateTime.add(now, -2, :day),
          retention: 1,
          expires_at: DateTime.add(now, -1, :day)
        }

        PostgresIndex.create(driver, expired)
        assert PostgresIndex.cleanup!(driver, before: now) == 1
        assert PostgresIndex.find(driver, expired.reference) == nil
        assert PostgresIndex.find(driver, final.reference)

        Postgrex.query!(connection, "DROP TABLE #{table}", [])
    end
  end

  test "PostgreSQL index rejects unsafe table names" do
    assert_raise ArgumentError, ~r/invalid PostgreSQL table name/, fn ->
      PostgresIndex.new(self(), table_name: "traces; DROP TABLE users")
    end
  end

  defp postgres_record(reference, first_at, state, tags, duration) do
    %TraceRecord{
      reference: reference,
      key: "jobs/postgres/page",
      state: state,
      tags: tags,
      meta: %{"source" => "integration"},
      context: %{"tenant_id" => 42},
      duration: duration,
      counters: TraceRecord.empty_counters(),
      first_at: first_at,
      last_at: first_at,
      retention: 7,
      expires_at: DateTime.add(first_at, 7, :day)
    }
  end
end
