defmodule Trifle.Traces.DataDriverTest do
  use ExUnit.Case

  alias Trifle.Traces.TraceRecord
  alias Trifle.Traces.Driver.Data.File, as: FileDriver
  alias Trifle.Traces.Driver.Data.S3

  defmodule FakeS3 do
    @behaviour Trifle.Traces.Driver.Data.S3Client

    def put_object(agent, bucket, key, body) do
      Agent.update(agent, &put_in(&1, [:objects, {bucket, key}], body))
    end

    def get_object(agent, bucket, key),
      do: Agent.get(agent, &get_in(&1, [:objects, {bucket, key}]))

    def list_objects(agent, bucket, prefix) do
      Agent.get(agent, fn state ->
        state.objects
        |> Map.keys()
        |> Enum.filter(fn {stored_bucket, key} ->
          stored_bucket == bucket and String.starts_with?(key, prefix)
        end)
        |> Enum.map(&elem(&1, 1))
      end)
    end

    def delete_objects(agent, bucket, keys) do
      Agent.update(agent, fn state ->
        update_in(
          state.objects,
          &Enum.reduce(keys, &1, fn key, objects -> Map.delete(objects, {bucket, key}) end)
        )
      end)
    end

    def put_lifecycle(agent, bucket, rules),
      do: Agent.update(agent, &put_in(&1, [:lifecycles, bucket], rules))

    def object_size(agent, bucket, key) do
      case get_object(agent, bucket, key) do
        nil -> nil
        body -> byte_size(body)
      end
    end

    def get_object_range(agent, bucket, key, first, last) do
      send(self(), {:s3_range, key, first, last})
      # Like S3, a range reaching past the end returns the bytes that exist.
      body = get_object(agent, bucket, key)
      binary_part(body, first, min(last, byte_size(body) - 1) - first + 1)
    end
  end

  # An adapter written before ranged reads existed.
  defmodule LegacyS3 do
    defdelegate put_object(agent, bucket, key, body), to: FakeS3
    defdelegate get_object(agent, bucket, key), to: FakeS3
  end

  # An endpoint that ignores Range and answers with the whole object.
  defmodule IgnoresRangeS3 do
    defdelegate put_object(agent, bucket, key, body), to: FakeS3
    defdelegate get_object(agent, bucket, key), to: FakeS3
    defdelegate object_size(agent, bucket, key), to: FakeS3
    def get_object_range(agent, bucket, key, _first, _last), do: get_object(agent, bucket, key)
  end

  # A data driver written before ranged reads existed.
  defmodule LegacyDriver do
    defstruct [:body]
    def read_artifact(%{body: body}, _record, _name), do: body
  end

  setup do
    record = %TraceRecord{
      reference: "01TESTREFERENCE000000000000",
      key: "jobs/import/products",
      state: :running,
      counters: TraceRecord.empty_counters(),
      parts: 2,
      retention: 3,
      first_at: DateTime.utc_now(),
      last_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 3, :day),
      bucket_name: "traces-a"
    }

    entries = [
      %{at: 1_700_000_000, message: "one", state: :success, type: :text, level: 0},
      %{at: 1_700_000_001.123456, message: "two", state: :error, type: :head, level: 1}
    ]

    %{record: record, entries: entries}
  end

  test "File round-trips parts and artifacts with Ruby-compatible paths", context do
    root =
      Path.join(System.tmp_dir!(), "trifle-traces-file-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    driver = FileDriver.new(path: root, gzip: true)
    FileDriver.setup!(path: root)

    FileDriver.write_part(driver, context.record, 1, [hd(context.entries)])
    FileDriver.write_part(driver, context.record, 2, [List.last(context.entries)])
    FileDriver.write_artifact(driver, context.record, "report.txt", payload: "report")

    assert FileDriver.read(driver, context.record) == context.entries
    assert FileDriver.read_artifact(driver, context.record, "report.txt") == "report"

    expected =
      Path.join([root, "3", "jobs/import/products", context.record.reference, "data_1.json.gz"])

    assert File.exists?(expected)

    FileDriver.delete(driver, context.record)
    refute File.exists?(Path.dirname(expected))
  end

  test "File cleanup removes expired traces and preserves current ones", context do
    root =
      Path.join(System.tmp_dir!(), "trifle-traces-cleanup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    driver = FileDriver.new(path: root)

    FileDriver.write_part(driver, context.record, 1, context.entries)
    trace_dir = Path.join([root, "3", context.record.key, context.record.reference])
    old = DateTime.utc_now() |> DateTime.add(-4, :day) |> DateTime.to_unix()
    File.touch!(trace_dir, old)

    current = %{context.record | reference: "current"}
    FileDriver.write_part(driver, current, 1, context.entries)
    FileDriver.cleanup!(driver)

    refute File.exists?(trace_dir)
    assert File.exists?(Path.join([root, "3", current.key, current.reference]))
  end

  test "S3 round-trips payloads, artifacts, deletion, and lifecycle setup", context do
    {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)

    driver =
      S3.new(
        adapter: FakeS3,
        client: agent,
        buckets: ["traces-a", "traces-b"],
        prefix: "traces",
        gzip: true
      )

    S3.write_part(driver, context.record, 1, [hd(context.entries)])
    S3.write_part(driver, context.record, 2, [List.last(context.entries)])
    S3.write_artifact(driver, context.record, "report.txt", payload: "report")

    assert S3.read(driver, context.record) == context.entries
    assert S3.read_artifact(driver, context.record, "report.txt") == "report"

    S3.delete(driver, context.record)
    assert Agent.get(agent, & &1.objects) == %{}

    S3.setup!(adapter: FakeS3, client: agent, buckets: ["traces-a"], retentions: [3, 30])
    rules = Agent.get(agent, & &1.lifecycles["traces-a"])
    assert Enum.map(rules, & &1.id) == ["trifle-traces-3d", "trifle-traces-30d"]
  end

  describe "ranged artifact reads" do
    setup context do
      root =
        Path.join(System.tmp_dir!(), "trifle-traces-range-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)
      s3 = S3.new(adapter: FakeS3, client: agent, buckets: ["traces-a"])
      drivers = [FileDriver.new(path: root), Trifle.Traces.Driver.Data.Memory.new(), s3]

      for driver <- drivers do
        Trifle.Traces.Driver.call(driver, :write_artifact, [
          context.record,
          "a.bin",
          [payload: "0123456789"]
        ])
      end

      %{drivers: drivers, s3: s3}
    end

    test "every driver reports the stored size and returns only the requested bytes", context do
      record = context.record

      for driver <- context.drivers do
        config = [config: %{Trifle.Traces.Configuration.new() | data_driver: driver}]

        assert Trifle.Traces.artifact_size(record, "a.bin", config) == 10
        assert Trifle.Traces.artifact_size(record, "missing", config) == nil
        assert Trifle.Traces.read_artifact_range(record, "a.bin", 0, 0, config) == "0"
        assert Trifle.Traces.read_artifact_range(record, "a.bin", 3, 6, config) == "3456"
        assert Trifle.Traces.read_artifact_range(record, "a.bin", 9, 9, config) == "9"

        # A range past the end is an error, never a silently short read.
        assert_raise Trifle.Traces.Error, fn ->
          Trifle.Traces.read_artifact_range(record, "a.bin", 8, 12, config)
        end
      end

      assert_received {:s3_range, _key, 3, 6}
    end

    test "S3 rejects an endpoint that ignores the range", context do
      driver = %{context.s3 | adapter: IgnoresRangeS3}

      assert_raise Trifle.Traces.Error, ~r/returned 10 bytes for bytes 3-6/, fn ->
        S3.read_artifact_range(driver, context.record, "a.bin", 3, 6)
      end
    end

    test "older S3 adapters and data drivers fall back to whole reads", context do
      record = context.record
      legacy = %{context.s3 | adapter: LegacyS3}
      assert S3.artifact_size(legacy, record, "a.bin") == 10
      assert S3.read_artifact_range(legacy, record, "a.bin", 3, 6) == "3456"

      config = fn body ->
        [config: %{Trifle.Traces.Configuration.new() | data_driver: %LegacyDriver{body: body}}]
      end

      assert Trifle.Traces.artifact_size(record, "a.bin", config.("0123456789")) == 10

      assert Trifle.Traces.read_artifact_range(record, "a.bin", 3, 6, config.("0123456789")) ==
               "3456"

      assert Trifle.Traces.artifact_size(record, "a.bin", config.(nil)) == nil
    end
  end

  describe "part size limits" do
    setup context do
      root =
        Path.join(System.tmp_dir!(), "trifle-traces-cap-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)
      s3 = [client: agent, buckets: ["traces-a"], gzip: true]

      # Highly compressible: a few hundred bytes stored, about 200 KB inflated.
      bomb = [
        %{at: 1, message: String.duplicate("a", 200_000), state: :success, type: :text, level: 0}
      ]

      builders = [
        fn options -> FileDriver.new([path: root, gzip: true] ++ options) end,
        fn options -> S3.new([adapter: FakeS3] ++ s3 ++ options) end,
        fn options -> S3.new([adapter: LegacyS3, prefix: "legacy"] ++ s3 ++ options) end
      ]

      for build <- builders do
        driver = build.([])
        Trifle.Traces.Driver.call(driver, :write_part, [context.record, 1, context.entries])
        Trifle.Traces.Driver.call(driver, :write_part, [context.record, 2, bomb])
      end

      %{builders: builders, bomb: bomb}
    end

    test "parts are unlimited by default and readable within the limits", context do
      for build <- context.builders,
          options <- [[], [max_part_bytes: 100_000, max_part_inflated_bytes: 1_000_000]] do
        driver = build.(options)

        assert Trifle.Traces.Driver.call(driver, :read_part, [context.record, 1]) ==
                 context.entries

        assert Trifle.Traces.Driver.call(driver, :read_part, [context.record, 2]) == context.bomb
      end
    end

    test "a part over the stored-size limit is refused before it is read", context do
      for build <- context.builders do
        error =
          assert_raise Trifle.Traces.Error, fn ->
            Trifle.Traces.Driver.call(build.(max_part_bytes: 50), :read_part, [context.record, 1])
          end

        assert error.reason == :too_large
      end

      # The capable adapter was asked for the size only, never for the body.
      refute_received {:s3_range, _, _, _}
    end

    test "a small archive that inflates past the limit is refused", context do
      for build <- context.builders do
        driver = build.(max_part_bytes: 100_000, max_part_inflated_bytes: 50_000)

        error =
          assert_raise Trifle.Traces.Error, fn ->
            Trifle.Traces.Driver.call(driver, :read_part, [context.record, 2])
          end

        assert error.reason == :too_large
      end
    end

    test "a truncated archive fails instead of looping" do
      body = [%{message: String.duplicate("b", 50_000)}] |> Jason.encode!() |> :zlib.gzip()
      cut = binary_part(body, 0, div(byte_size(body), 2))

      assert_raise Trifle.Traces.Error, ~r/truncated/, fn ->
        Trifle.Traces.Driver.Data.Encoding.unpack_entries(cut, true, 1_000_000)
      end
    end
  end

  test "drivers handle empty traces and validate S3 buckets", context do
    root =
      Path.join(System.tmp_dir!(), "trifle-traces-empty-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    empty = %{context.record | parts: 0}
    assert FileDriver.read(FileDriver.new(path: root), empty) == []

    assert_raise ArgumentError, "S3 driver requires at least one bucket", fn ->
      S3.new(buckets: [])
    end
  end

  for mode <- [:live, :deferred] do
    test "#{mode} wrapup cleans File and S3 attachment sources while preserving stored copies" do
      root = Path.join(System.tmp_dir!(), "trifle-upload-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)

      for data <- [
            FileDriver.new(path: Path.join(root, "storage"), gzip: true),
            S3.new(adapter: FakeS3, client: agent, buckets: ["traces-a"], gzip: true)
          ] do
        path = Path.join(root, "source.txt")
        File.write!(path, "report")

        config =
          Trifle.Traces.Configuration.new(
            index_driver: Trifle.Traces.Driver.Index.Memory.new(),
            data_driver: data,
            bump_every: 0
          )

        {:ok, tracer} =
          Trifle.Traces.start_tracer("jobs/cleanup", config: config, mode: unquote(mode))

        Trifle.Traces.artifact("public.txt", path, tracer: tracer)
        assert File.exists?(path)
        final = Trifle.Traces.wrapup(tracer: tracer)

        refute File.exists?(path)
        record = Trifle.Traces.find(final.reference, config: config)
        assert Trifle.Traces.read_artifact(record, "public.txt", config: config) == "report"
      end
    end

    test "#{mode} mode stores the selected S3 bucket name in the index" do
      {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)
      data = S3.new(adapter: FakeS3, client: agent, buckets: ["selected-traces"])

      config =
        Trifle.Traces.Configuration.new(
          index_driver: Trifle.Traces.Driver.Index.Memory.new(),
          data_driver: data,
          default_mode: unquote(mode),
          bump_every: 0
        )

      {:ok, tracer} = Trifle.Traces.start_tracer("jobs/bucket-name", config: config)
      Trifle.Traces.trace("stored", tracer: tracer)
      final = Trifle.Traces.wrapup(tracer: tracer)
      record = Trifle.Traces.find(final.reference, config: config)

      assert record.bucket_name == "selected-traces"
      changed = %{config | data_driver: %{data | buckets: ["replacement-traces"]}}
      assert Enum.any?(Trifle.Traces.payload(record, config: changed), &(&1.message == "stored"))
    end
  end

  test "S3 uses the recorded bucket after configured buckets are reordered or replaced",
       context do
    {:ok, agent} = Agent.start_link(fn -> %{objects: %{}, lifecycles: %{}} end)
    driver = S3.new(adapter: FakeS3, client: agent, buckets: ["traces-a", "traces-b"])
    record = context.record

    assert S3.generate_bucket_name(driver) in ["traces-a", "traces-b"]
    S3.write_part(driver, record, 1, [hd(context.entries)])
    S3.write_artifact(driver, record, "report.txt", payload: "report")

    for buckets <- [["traces-b", "traces-a"], ["traces-new"]] do
      changed = %{driver | buckets: buckets}

      assert S3.read_part(changed, record, 1) == [hd(context.entries)]
      assert S3.read_artifact(changed, record, "report.txt") == "report"
      S3.write_part(changed, record, 2, [List.last(context.entries)])
      S3.write_artifact(changed, record, "continued.txt", payload: "continued")
      assert S3.read(changed, record) == context.entries
      assert S3.read_artifact(changed, record, "continued.txt") == "continued"
    end

    assert Agent.get(agent, fn state ->
             Enum.all?(Map.keys(state.objects), fn {bucket, _key} -> bucket == "traces-a" end)
           end)

    S3.delete(%{driver | buckets: ["traces-new"]}, record)
    assert Agent.get(agent, & &1.objects) == %{}
  end
end
