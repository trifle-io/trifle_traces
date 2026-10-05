defmodule Trifle.Traces.StatsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Trifle.Traces.{Configuration, Tracer}
  alias Trifle.Traces.Driver.Data.Memory, as: MemoryData
  alias Trifle.Traces.Driver.Index.Memory, as: MemoryIndex

  defmodule FailingIndex do
    @behaviour Trifle.Traces.Driver.Index
    defstruct [:delegate, :attempts]

    def generate_reference(driver), do: MemoryIndex.generate_reference(driver.delegate)
    def capabilities(driver), do: MemoryIndex.capabilities(driver.delegate)

    def create(driver, record) do
      attempt = Agent.get_and_update(driver.attempts, &{&1 + 1, &1 + 1})
      if attempt == 1, do: raise("storage unavailable")
      MemoryIndex.create(driver.delegate, record)
    end

    def update(driver, record), do: MemoryIndex.update(driver.delegate, record)
    def find(_driver, _reference), do: raise("unexpected index read")
    def search(_driver, _filters), do: raise("unexpected index search")
    def delete(driver, reference), do: MemoryIndex.delete(driver.delegate, reference)
  end

  setup do
    pid = start_supervised!(Trifle.Stats.Driver.Process)

    stats =
      Trifle.Stats.Configuration.configure(
        Trifle.Stats.Driver.Process.new(pid),
        time_zone: "Etc/UTC",
        track_granularities: ["10m", "1h"],
        buffer_enabled: false
      )

    config =
      Configuration.new(
        index_driver: MemoryIndex.new(),
        data_driver: MemoryData.new(),
        stats_config: stats,
        bump_every: 0
      )

    %{stats: stats, config: config, stats_pid: pid}
  end

  defp values(stats, record, key \\ "jobs/import/products", granularity \\ "10m") do
    %{values: [values]} =
      Trifle.Stats.values(key, record.last_at, record.last_at, granularity, stats)

    values
  end

  for mode <- [:live, :deferred] do
    test "tracks finalized #{mode} traces once and preserves user callbacks", context do
      mode = unquote(mode)
      parent = self()

      config =
        Configuration.add_callback(context.config, :wrapup, fn tracer ->
          send(parent, {:callback, Tracer.trace_record(tracer)})
        end)

      {:ok, tracer} =
        Trifle.Traces.start_tracer("jobs/import/products", config: config, mode: mode)

      Trifle.Traces.trace("working", tracer: tracer)
      Trifle.Traces.warn(tracer: tracer)
      assert values(context.stats, Tracer.trace_record(tracer)) == %{}
      final = Trifle.Traces.wrapup(tracer: tracer)
      record = Tracer.trace_record(final)

      for granularity <- ["10m", "1h"] do
        assert values(context.stats, record, record.key, granularity) == %{
                 "count" => 1,
                 "states" => %{"warning" => 1},
                 "entries" => %{"count" => 2},
                 "duration" => %{
                   "count" => 1,
                   "sum" => record.duration,
                   "square" => record.duration * record.duration,
                   "states" => %{
                     "warning" => %{
                       "count" => 1,
                       "sum" => record.duration,
                       "square" => record.duration * record.duration
                     }
                   }
                 }
               }
      end

      assert values(context.stats, record, "jobs") == %{}
      assert_receive {:callback, ^record}
    end

    test "skips ignored #{mode} traces", context do
      {:ok, tracer} =
        Trifle.Traces.start_tracer("jobs/import/products",
          config: context.config,
          mode: unquote(mode)
        )

      Trifle.Traces.ignore(tracer: tracer)
      final = Trifle.Traces.wrapup(tracer: tracer)
      assert values(context.stats, Tracer.trace_record(final)) == %{}
    end
  end

  test "Stats is disabled unless a configuration is passed", context do
    assert Configuration.new().stats_config == nil
    config = %{context.config | stats_config: nil}
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/import/products", config: config)
    final = Trifle.Traces.wrapup(tracer: tracer)
    assert values(context.stats, Tracer.trace_record(final)) == %{}
  end

  test "supports Stats without persistence while retaining callback data", context do
    config = Configuration.new(stats_config: context.stats)

    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/import/products", config: config, mode: :deferred)

    Trifle.Traces.trace("working", tracer: tracer)
    final = Trifle.Traces.wrapup(tracer: tracer)
    assert length(final.data) == 2
    assert values(context.stats, Tracer.trace_record(final))["entries"]["count"] == 2
  end

  test "does not emit after failed persistence and emits after a successful retry without index reads",
       context do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    index = %FailingIndex{delegate: context.config.index_driver, attempts: attempts}
    config = %{context.config | index_driver: index}

    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/import/products", config: config, mode: :deferred)

    assert {:error, %RuntimeError{message: "storage unavailable"}} = Tracer.wrapup(tracer)
    assert values(context.stats, Tracer.trace_record(tracer)) == %{}
    final = Trifle.Traces.wrapup(tracer: tracer)
    assert values(context.stats, Tracer.trace_record(final))["count"] == 1
  end

  test "logs Stats exits without failing persistence or skipping user callbacks", context do
    parent = self()
    config = Configuration.add_callback(context.config, :wrapup, &send(parent, {:wrapped, &1}))
    stop_supervised!(Trifle.Stats.Driver.Process)

    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/import/products", config: config, mode: :deferred)

    assert capture_log(fn ->
             final = Trifle.Traces.wrapup(tracer: tracer)
             assert Trifle.Traces.find(final.reference, config: config).state == :success
           end) =~ "stats tracking failed"

    assert_receive {:wrapped, _}
  end
end
