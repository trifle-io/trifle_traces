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
      %{at: 1_700_000_001, message: "two", state: :error, type: :head, level: 1}
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
