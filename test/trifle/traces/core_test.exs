defmodule Trifle.Traces.CoreTest do
  use ExUnit.Case

  alias Trifle.Traces.{Configuration, Tracer}

  setup do
    original = Application.get_env(:trifle_traces, :configuration)
    Application.delete_env(:trifle_traces, :configuration)

    on_exit(fn ->
      if original,
        do: Application.put_env(:trifle_traces, :configuration, original),
        else: Application.delete_env(:trifle_traces, :configuration)
    end)

    :ok
  end

  test "operations are transparent without a current tracer" do
    assert Trifle.Traces.trace("plain") == nil
    assert Trifle.Traces.trace("block", fn -> 42 end) == 42
    assert Trifle.Traces.tag("invoice:1") == nil
    assert Trifle.Traces.fail() == nil
    assert Trifle.Traces.warn() == nil
    assert Trifle.Traces.success() == nil
    assert Trifle.Traces.ignore() == nil
    assert Trifle.Traces.wrapup() == nil
  end

  test "global configuration backs the concise API and null reads" do
    config = Trifle.Traces.configure(serializer: Trifle.Traces.Serializer.Json)

    assert Trifle.Traces.configuration() == config

    assert Trifle.Traces.with_tracer("jobs/configured", fn ->
             assert %{answer: 42} == Trifle.Traces.trace("answer", fn -> %{answer: 42} end)
             :ok
           end) == :ok

    assert Trifle.Traces.find("missing") == nil
    assert Trifle.Traces.search() == %{traces: [], cursor: nil}

    record = %Trifle.Traces.TraceRecord{reference: "missing", key: "jobs/missing"}
    assert Trifle.Traces.payload(record) == []
    assert Trifle.Traces.read_artifact(record, "missing.txt") == nil
  end

  test "records lines, nested block results, tags, and state" do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/import", meta: [42])

    Trifle.Traces.trace("section", tracer: tracer, head: true, state: :debug)

    result =
      Trifle.Traces.trace("outer", [tracer: tracer], fn ->
        Trifle.Traces.trace("inner", tracer: tracer)
        %{answer: 42}
      end)

    Trifle.Traces.tag("tenant:1", tracer: tracer)
    Trifle.Traces.warn(tracer: tracer)

    snapshot = Tracer.snapshot(tracer)
    assert result == %{answer: 42}
    assert snapshot.state == :warning
    assert snapshot.tags == ["tenant:1"]
    assert Tracer.keys(snapshot) == ["jobs", "jobs/import"]
    assert Enum.find(snapshot.data, &(&1.message == "section")).type == :head
    assert Enum.find(snapshot.data, &(&1.message == "inner")).level == 1
    assert List.last(snapshot.data).message =~ "%{answer: 42}"

    assert {:ok, final} = Tracer.wrapup(tracer)
    assert final.state == :warning
    refute Process.alive?(tracer)
  end

  test "state helpers and lifecycle callbacks expose safe snapshots" do
    parent = self()

    config =
      Configuration.new(
        bump_every: 0,
        on_liftoff: fn tracer -> send(parent, {:lifecycle, :liftoff, tracer}) end,
        on_bump: fn tracer -> send(parent, {:lifecycle, :bump, tracer}) end,
        on_wrapup: fn tracer -> send(parent, {:lifecycle, :wrapup, tracer}) end
      )

    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/lifecycle", config: config)
    assert_receive {:lifecycle, :liftoff, liftoff}
    assert liftoff.dispatcher == nil

    assert Trifle.Traces.fail(tracer: tracer) == :error
    assert Trifle.Traces.warn(tracer: tracer) == :warning
    assert Trifle.Traces.success(tracer: tracer) == :success
    assert Trifle.Traces.trace("bump", tracer: tracer) == nil
    assert_receive {:lifecycle, :bump, bumped}
    assert bumped.state == :success

    final = Trifle.Traces.wrapup(tracer: tracer)
    assert_receive {:lifecycle, :wrapup, wrapped}
    assert wrapped == final
  end

  test "block errors are recorded and re-raised" do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/error")

    assert_raise ArgumentError, "nope", fn ->
      Trifle.Traces.trace("explode", [tracer: tracer], fn -> raise ArgumentError, "nope" end)
    end

    snapshot = Tracer.snapshot(tracer)
    closing = Enum.find(snapshot.data, &(&1.message == "explode \u21B5"))
    assert closing.state == :error
    assert snapshot.levels == %{}
    Trifle.Traces.wrapup(tracer: tracer)
  end

  test "with_tracer restores context and wraps failures" do
    parent = self()
    previous = spawn(fn -> Process.sleep(:infinity) end)
    Process.put({Trifle.Traces, :current_tracer}, previous)

    config = Configuration.new(on_wrapup: fn tracer -> send(parent, {:wrapped, tracer}) end)

    assert_raise RuntimeError, "broken", fn ->
      Trifle.Traces.with_tracer("jobs/wrapped", [config: config], fn ->
        assert is_pid(Trifle.Traces.current_tracer())
        raise "broken"
      end)
    end

    assert Trifle.Traces.current_tracer() == previous
    assert_receive {:wrapped, snapshot}
    assert snapshot.state == :error
    assert Enum.any?(snapshot.data, &String.starts_with?(&1.message, "Exception: broken"))
    Process.exit(previous, :kill)
  end

  test "attach shares a tracer while keeping nesting per Task" do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/concurrent")

    Trifle.Traces.trace("parent", [tracer: tracer], fn ->
      tasks =
        Enum.map(1..4, fn index ->
          Task.async(fn ->
            Trifle.Traces.attach(tracer, fn ->
              Trifle.Traces.trace("task-#{index}", fn -> index end)
            end)
          end)
        end)

      Task.await_many(tasks)
    end)

    snapshot = Tracer.snapshot(tracer)
    task_entries = Enum.filter(snapshot.data, &String.match?(&1.message, ~r/^task-\d+ ↴$/))
    assert length(task_entries) == 4
    assert Enum.all?(task_entries, &(&1.level == 0))
    assert snapshot.levels == %{}
    Trifle.Traces.wrapup(tracer: tracer)
  end

  test "attach restores a previous process-local tracer after errors" do
    {:ok, previous} = Trifle.Traces.start_tracer("jobs/previous")
    {:ok, attached} = Trifle.Traces.start_tracer("jobs/attached")
    Process.put({Trifle.Traces, :current_tracer}, previous)

    assert_raise RuntimeError, "attached failure", fn ->
      Trifle.Traces.attach(attached, fn -> raise "attached failure" end)
    end

    assert Trifle.Traces.current_tracer() == previous
    Trifle.Traces.wrapup(tracer: previous)
    Trifle.Traces.wrapup(tracer: attached)
  end

  test "serializer failure falls back to Inspect" do
    defmodule BrokenSerializer do
      @behaviour Trifle.Traces.Serializer
      def sanitize(_), do: raise("broken")
    end

    config = Configuration.new(serializer: BrokenSerializer)
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/serialize", config: config)
    assert %{value: 1} == Trifle.Traces.trace("value", [tracer: tracer], fn -> %{value: 1} end)
    assert Tracer.snapshot(tracer).data |> List.last() |> Map.fetch!(:message) =~ "%{value: 1}"
    Trifle.Traces.wrapup(tracer: tracer)
  end

  test "accepts explicit references and string modes and rejects invalid modes" do
    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/reference", reference: "explicit", mode: "deferred")

    snapshot = Tracer.snapshot(tracer)
    assert snapshot.reference == "explicit"
    assert snapshot.mode == :deferred
    Trifle.Traces.wrapup(tracer: tracer)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             Trifle.Traces.start_tracer("jobs/invalid", mode: :invalid)

    assert message =~ "invalid trace mode"
  end

  test "a crashing attached process does not leave stale nesting state" do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/crashing-task")
    parent = self()

    pid =
      spawn(fn ->
        Trifle.Traces.attach(tracer, fn ->
          :ok = Tracer.begin_trace(tracer, "unfinished", [])
          send(parent, :nested)
          exit(:boom)
        end)
      end)

    monitor = Process.monitor(pid)
    assert_receive :nested
    assert_receive {:DOWN, ^monitor, :process, ^pid, :boom}

    assert_eventually(fn -> Tracer.snapshot(tracer).levels == %{} end)
    Trifle.Traces.wrapup(tracer: tracer)
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
