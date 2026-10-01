defmodule Trifle.Traces.ArtifactCleanupTest do
  use ExUnit.Case

  alias Trifle.Traces.Configuration
  alias Trifle.Traces.Driver.Data.Memory, as: MemoryData
  alias Trifle.Traces.Driver.Index.Memory, as: MemoryIndex

  defmodule FailingData do
    defstruct [:delegate, :failure]

    def generate_bucket_name(driver), do: MemoryData.generate_bucket_name(driver.delegate)

    def write_part(driver, record, part, entries) do
      fail_if_requested(driver, :write_part)
      MemoryData.write_part(driver.delegate, record, part, entries)
    end

    def write_artifact(driver, record, name, options) do
      fail_if_requested(driver, :write_artifact)
      MemoryData.write_artifact(driver.delegate, record, name, options)
    end

    def read_artifact(driver, record, name),
      do: MemoryData.read_artifact(driver.delegate, record, name)

    def delete(driver, record), do: MemoryData.delete(driver.delegate, record)

    defp fail_if_requested(driver, operation) do
      if Agent.get(driver.failure, &(&1 == operation)), do: raise("storage down")
    end
  end

  defmodule FailingIndex do
    defstruct [:delegate, :failure]

    def generate_reference(driver), do: MemoryIndex.generate_reference(driver.delegate)
    def capabilities(driver), do: MemoryIndex.capabilities(driver.delegate)

    def create(driver, record) do
      fail_if_requested(driver, :create)
      MemoryIndex.create(driver.delegate, record)
    end

    def update(driver, record) do
      fail_if_requested(driver, :update)
      MemoryIndex.update(driver.delegate, record)
    end

    def find(driver, reference), do: MemoryIndex.find(driver.delegate, reference)
    def delete(driver, reference), do: MemoryIndex.delete(driver.delegate, reference)

    defp fail_if_requested(driver, operation) do
      if Agent.get(driver.failure, &(&1 == operation)), do: raise("storage down")
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "trifle-sources-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "source.txt")
    File.write!(path, "artifact")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, failure} = Agent.start_link(fn -> nil end)

    config =
      Configuration.new(
        index_driver: %FailingIndex{delegate: MemoryIndex.new(), failure: failure},
        data_driver: %FailingData{delegate: MemoryData.new(), failure: failure},
        bump_every: 0
      )

    %{path: path, config: config, failure: failure}
  end

  for mode <- [:live, :deferred] do
    test "#{mode} removes sources only at successful wrapup and preserves stored bytes",
         context do
      callback = fn _ -> refute File.exists?(context.path) end
      config = Configuration.add_callback(context.config, :wrapup, callback)

      {:ok, tracer} =
        Trifle.Traces.start_tracer("jobs/artifact", config: config, mode: unquote(mode))

      Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
      assert File.exists?(context.path)

      final = Trifle.Traces.wrapup(tracer: tracer)
      refute File.exists?(context.path)
      record = Trifle.Traces.find(final.reference, config: config)
      assert Trifle.Traces.read_artifact(record, "public.txt", config: config) == "artifact"
    end

    test "#{mode} respects cleanup opt-outs, including repeated attachments", context do
      {:ok, tracer} =
        Trifle.Traces.start_tracer("jobs/retained", config: context.config, mode: unquote(mode))

      Trifle.Traces.artifact("retained.txt", context.path, tracer: tracer, cleanup: false)
      Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
      Trifle.Traces.wrapup(tracer: tracer)
      assert File.read!(context.path) == "artifact"
    end
  end

  for {mode, operation} <- [
        {:deferred, :write_artifact},
        {:deferred, :write_part},
        {:deferred, :create},
        {:live, :update}
      ] do
    test "#{mode} retains sources after failed #{operation} and cleans after retry", context do
      {:ok, tracer} =
        Trifle.Traces.start_tracer("jobs/retry", config: context.config, mode: unquote(mode))

      Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
      Agent.update(context.failure, fn _ -> unquote(operation) end)

      assert_raise RuntimeError, "storage down", fn -> Trifle.Traces.wrapup(tracer: tracer) end
      assert File.read!(context.path) == "artifact"

      Agent.update(context.failure, fn _ -> nil end)
      final = Trifle.Traces.wrapup(tracer: tracer)
      refute File.exists?(context.path)
      record = Trifle.Traces.find(final.reference, config: context.config)

      assert Trifle.Traces.read_artifact(record, "public.txt", config: context.config) ==
               "artifact"
    end
  end

  test "a suppressed wrapup failure keeps sources", context do
    config = %{context.config | error_handler: fn _, _, _ -> :ok end}
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/suppressed", config: config, mode: :deferred)
    Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    Agent.update(context.failure, fn _ -> :create end)
    Trifle.Traces.wrapup(tracer: tracer)
    assert File.read!(context.path) == "artifact"
  end

  test "a failed live bump retains sources for a successful wrapup retry", context do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/bump-retry", config: context.config)
    Agent.update(context.failure, fn _ -> :write_part end)

    ExUnit.CaptureLog.capture_log(fn ->
      Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    end)

    assert File.read!(context.path) == "artifact"

    Agent.update(context.failure, fn _ -> nil end)
    final = Trifle.Traces.wrapup(tracer: tracer)
    refute File.exists?(context.path)
    record = Trifle.Traces.find(final.reference, config: context.config)
    assert Trifle.Traces.read_artifact(record, "public.txt", config: context.config) == "artifact"
  end

  test "callback-only and Null data drivers keep sources", context do
    for config <- [Configuration.new(), Configuration.new(index_driver: MemoryIndex.new())] do
      {:ok, tracer} = Trifle.Traces.start_tracer("jobs/null", config: config)
      Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
      Trifle.Traces.wrapup(tracer: tracer)
      assert File.read!(context.path) == "artifact"
    end
  end

  test "ignored wrapup cleans uploaded live sources and keeps deferred sources", context do
    {:ok, tracer} =
      Trifle.Traces.start_tracer("jobs/ignored", config: context.config, mode: :deferred)

    Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    Trifle.Traces.ignore(tracer: tracer)
    Trifle.Traces.wrapup(tracer: tracer)
    assert File.exists?(context.path)

    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/ignored", config: context.config)
    Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    Trifle.Traces.ignore(tracer: tracer)
    Trifle.Traces.wrapup(tracer: tracer)
    refute File.exists?(context.path)
  end

  test "already removed files are harmless and cleanup failures are logged", context do
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/missing", config: context.config)
    Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    File.rm!(context.path)
    Trifle.Traces.wrapup(tracer: tracer)

    File.write!(context.path, "artifact")
    {:ok, tracer} = Trifle.Traces.start_tracer("jobs/cleanup-error", config: context.config)
    Trifle.Traces.artifact("public.txt", context.path, tracer: tracer)
    File.rm!(context.path)
    File.mkdir!(context.path)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        final = Trifle.Traces.wrapup(tracer: tracer)
        assert Trifle.Traces.find(final.reference, config: context.config).state == :success
      end)

    assert log =~ "artifact cleanup failed"
    assert File.dir?(context.path)
  end
end
