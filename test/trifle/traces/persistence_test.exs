defmodule Trifle.Traces.PersistenceTest do
  use ExUnit.Case

  alias Trifle.Traces.{Configuration, TraceRecord, Tracer}
  alias Trifle.Traces.Driver.Data.Memory, as: MemoryData
  alias Trifle.Traces.Driver.Index.Memory, as: MemoryIndex

  defmodule FlakyData do
    @behaviour Trifle.Traces.Driver.Data

    defstruct [:delegate, :attempts]

    def new do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      %__MODULE__{delegate: MemoryData.new(), attempts: attempts}
    end

    def generate_bucket_name(driver), do: MemoryData.generate_bucket_name(driver.delegate)

    def write_part(driver, record, part, entries) do
      attempt = Agent.get_and_update(driver.attempts, &{&1 + 1, &1 + 1})
      if attempt == 2, do: raise("storage down")
      MemoryData.write_part(driver.delegate, record, part, entries)
    end

    def write_artifact(driver, record, name, options),
      do: MemoryData.write_artifact(driver.delegate, record, name, options)

    def read_part(driver, record, part), do: MemoryData.read_part(driver.delegate, record, part)
    def read(driver, record), do: MemoryData.read(driver.delegate, record)

    def read_artifact(driver, record, name),
      do: MemoryData.read_artifact(driver.delegate, record, name)

    def delete(driver, record), do: MemoryData.delete(driver.delegate, record)
  end

  defmodule CreateOnlyIndex do
    @behaviour Trifle.Traces.Driver.Index

    defstruct []

    def generate_reference(_driver), do: Trifle.Traces.Ref.generate()
    def capabilities(_driver), do: %{update: false, delete: false, search: false, ttl: :none}
    def create(_driver, record), do: record.reference
    def update(_driver, _record), do: raise("update is unsupported")
    def delete(_driver, _reference), do: nil
    def find(_driver, _reference), do: nil
    def search(_driver, _filters), do: %{traces: [], cursor: nil}
  end

  defmodule WriteOnlyIndex do
    @behaviour Trifle.Traces.Driver.Index

    defstruct [:owner]

    def generate_reference(_driver), do: Trifle.Traces.Ref.generate()
    def capabilities(_driver), do: %{update: true, delete: true, search: false, ttl: :none}

    def create(driver, record) do
      send(driver.owner, {:index, :create, record})
      record.reference
    end

    def update(driver, record) do
      send(driver.owner, {:index, :update, record})
      record.reference
    end

    def find(_driver, _reference), do: raise("unexpected index read")
    def search(_driver, _filters), do: raise("unexpected index search")
    def delete(_driver, _reference), do: nil
  end

  defp config(options) do
    Configuration.new(
      Keyword.merge(
        [index_driver: MemoryIndex.new(), data_driver: MemoryData.new(), bump_every: 0],
        options
      )
    )
  end

  test "live mode persists initial and incremental parts" do
    config = config(context: %{tenant_id: 42}, retention: 3)
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/import/products", config: config)
    Trifle.Traces.tag("tenant:42", tracer: tracer)
    Trifle.Traces.trace("working", tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)

    record = Trifle.Traces.find(final.reference, config: config)
    entries = Trifle.Traces.payload(record, config: config)

    assert record.state == :success
    assert record.tags == ["tenant:42"]
    assert record.context == %{tenant_id: 42}
    assert record.retention == 3
    assert record.parts == 2
    assert record.length == 2
    assert record.counters.states.success == 2

    assert Enum.map(entries, & &1.message) == [
             "Tracer has been initialized for jobs/import/products",
             "working"
           ]
  end

  test "oversized messages are offloaded as readable artifacts" do
    config = config(payload_size_limit: 8)
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/oversized", config: config)
    Trifle.Traces.trace(String.duplicate("x", 20), tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)
    record = Trifle.Traces.find(final.reference, config: config)
    media = Trifle.Traces.payload(record, config: config) |> Enum.find(&(&1[:size] == 20))

    assert media.size == 20

    assert Trifle.Traces.read_artifact(record, media.message, config: config) ==
             String.duplicate("x", 20)
  end

  test "deferred mode writes one part only at wrapup" do
    config = config(default_mode: :deferred)
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/deferred", config: config)
    snapshot = Trifle.Traces.Tracer.snapshot(tracer)
    assert Trifle.Traces.find(snapshot.reference, config: config) == nil

    Trifle.Traces.trace("one", tracer: tracer)
    Trifle.Traces.trace("two", tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)
    record = Trifle.Traces.find(final.reference, config: config)

    assert record.parts == 1
    assert record.length == 3
  end

  test "callbacks and snapshots expose the persisted record without reading the index" do
    parent = self()

    for mode <- [:live, :deferred] do
      data = MemoryData.new()

      config =
        config(
          index_driver: %WriteOnlyIndex{owner: parent},
          data_driver: data,
          context: %{tenant_id: 42},
          retention: 3,
          on_liftoff: fn tracer -> send(parent, {:callback, :liftoff, tracer}) end,
          on_bump: fn tracer -> send(parent, {:callback, :bump, tracer}) end,
          on_wrapup: fn tracer -> send(parent, {:callback, :wrapup, tracer}) end
        )

      {:ok, tracer} = Trifle.Traces.start_tracer("jobs/metadata", config: config, mode: mode)
      initial = Tracer.trace_record(tracer)
      assert initial.reference == Tracer.snapshot(tracer).reference
      assert initial.parts == if(mode == :live, do: 1, else: 0)

      if mode == :live do
        assert_receive {:index, :create, ^initial}
        assert_receive {:callback, :liftoff, snapshot}
        assert Tracer.trace_record(snapshot) == initial
      else
        refute_receive {:index, _, _}
        refute_receive {:callback, _, _}
      end

      Trifle.Traces.tag("tenant:42", tracer: tracer)
      Trifle.Traces.tag("tenant:42", tracer: tracer)
      Trifle.Traces.trace("working", state: :warning, tracer: tracer)
      Trifle.Traces.warn(tracer: tracer)

      if mode == :live do
        assert_receive {:callback, :bump, snapshot}
        assert snapshot.trace_record.reference == initial.reference
        assert_receive {:callback, :bump, _}
        assert_receive {:callback, :bump, _}
        assert_receive {:index, :update, _}
      else
        assert :ets.info(data.parts, :size) == 0
        refute_receive {:index, _, _}
        refute_receive {:callback, _, _}
      end

      final = Trifle.Traces.wrapup(tracer: tracer)
      assert_receive {:callback, :wrapup, ^final}
      record = Tracer.trace_record(final)
      assert_receive {:index, event, ^record}
      assert event == if(mode == :live, do: :update, else: :create)
      refute_receive {:index, _, _}

      assert record.state == :warning
      assert record.tags == ["tenant:42"]
      assert record.context == %{tenant_id: 42}
      assert record.retention == 3
      assert record.bucket_name == nil
      assert record.parts == if(mode == :live, do: 2, else: 1)
      assert record.length == 2
      assert record.counters.states.success == 1
      assert record.counters.states.warning == 1
      assert record.counters.types.text == 2
      assert record.duration >= 0
      assert DateTime.compare(record.last_at, record.first_at) in [:eq, :gt]
      assert length(MemoryData.read(data, record)) == record.length
    end
  end

  test "live mode requires index updates while deferred mode accepts create-only indexes" do
    config =
      Configuration.new(
        index_driver: %CreateOnlyIndex{},
        data_driver: MemoryData.new()
      )

    assert {:error, {%Trifle.Traces.Error{message: message}, _stacktrace}} =
             Trifle.Traces.start_tracer("jobs/create-only", config: config)

    assert message =~ "does not support update"

    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/create-only", config: config, mode: :deferred)

    assert Trifle.Traces.wrapup(tracer: tracer).state == :success
  end

  test "a failed bump retains entries and retries them without double-counting" do
    data = FlakyData.new()

    config =
      Configuration.new(
        index_driver: MemoryIndex.new(),
        data_driver: data,
        bump_every: 0
      )

    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/retry", config: config)

    ExUnit.CaptureLog.capture_log(fn ->
      Trifle.Traces.trace("one", tracer: tracer)
    end)

    Trifle.Traces.trace("two", tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)
    record = Trifle.Traces.find(final.reference, config: config)

    assert Enum.map(Trifle.Traces.payload(record, config: config), & &1.message) == [
             "Tracer has been initialized for jobs/retry",
             "one",
             "two"
           ]

    assert record.length == 3
    assert record.counters.states.success == 3
  end

  test "artifact persistence preserves the explicit public name" do
    root = Path.join(System.tmp_dir!(), "trifle-artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "physical-name.txt")
    File.write!(path, "artifact")
    on_exit(fn -> File.rm_rf!(root) end)

    config = config([])
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/artifact", config: config)
    Trifle.Traces.artifact("public-name.txt", path, tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)
    record = Trifle.Traces.find(final.reference, config: config)

    assert Trifle.Traces.read_artifact(record, "public-name.txt", config: config) == "artifact"
  end

  test "ignore deletes live traces and skips deferred traces" do
    Enum.each([:live, :deferred], fn mode ->
      config = config(default_mode: mode)
      {:ok, tracer} = Trifle.Traces.start_tracer("jobs/ignored/#{mode}", config: config)
      reference = Trifle.Traces.Tracer.snapshot(tracer).reference
      Trifle.Traces.ignore(tracer: tracer)
      Trifle.Traces.wrapup(tracer: tracer)
      assert Trifle.Traces.find(reference, config: config) == nil
    end)
  end

  test "search combines filters and paginates newest first" do
    index = MemoryIndex.new()
    now = DateTime.utc_now()

    records =
      Enum.map(0..2, fn offset ->
        record = %TraceRecord{
          reference: Trifle.Traces.Ref.generate(DateTime.add(now, offset, :second)),
          key: if(offset == 2, do: "jobs/export", else: "jobs/import/#{offset}"),
          state: if(offset == 1, do: :error, else: :success),
          tags: if(offset == 1, do: ["failed", "tenant:1"], else: ["tenant:1"]),
          duration: offset * 1_000,
          counters: TraceRecord.empty_counters(),
          first_at: DateTime.add(now, offset, :second),
          last_at: DateTime.add(now, offset, :second),
          retention: 7,
          expires_at: DateTime.add(now, 7, :day)
        }

        MemoryIndex.create(index, record)
        record
      end)

    result =
      MemoryIndex.search(index, segment: "jobs/import", tags: %{all: ["failed"]}, state: :error)

    assert Enum.map(result.traces, & &1.reference) == [Enum.at(records, 1).reference]

    first = MemoryIndex.search(index, segment: "jobs", limit: 2)
    second = MemoryIndex.search(index, segment: "jobs", limit: 2, cursor: first.cursor)

    assert Enum.map(first.traces ++ second.traces, & &1.reference) ==
             records |> Enum.reverse() |> Enum.map(& &1.reference)
  end
end
