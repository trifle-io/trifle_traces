defmodule Trifle.Traces do
  @moduledoc """
  Structured execution tracing for Elixir jobs, requests, and integrations.

  A tracer is an explicit supervised process. `with_tracer/3` binds that
  process to the caller for the concise module-level API; use `attach/2` to
  propagate the same tracer deliberately into a Task.
  """

  alias Trifle.Traces.{Configuration, Context, Driver, Tracer}

  def configure(options) when is_list(options) do
    config = Configuration.new(options)
    Application.put_env(:trifle_traces, :configuration, config)
    config
  end

  def configuration do
    Application.get_env(:trifle_traces, :configuration) || Configuration.new()
  end

  def start_tracer(key, options \\ []) do
    ensure_started!()
    {config, options} = Keyword.pop(options, :config, configuration())
    config = if match?(%Configuration{}, config), do: config, else: Configuration.new(config)

    DynamicSupervisor.start_child(
      Trifle.Traces.TracerSupervisor,
      {Tracer, Keyword.merge(options, key: key, config: config)}
    )
  end

  def with_tracer(key, fun) when is_function(fun, 0), do: with_tracer(key, [], fun)

  def with_tracer(key, options, fun) when is_function(fun, 0) do
    {:ok, tracer} = start_tracer(key, options)
    previous = Context.put(tracer)

    try do
      try do
        result = fun.()
        wrapup(tracer: tracer)
        result
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          safely_record_failure(tracer, kind, reason)
          safely_wrapup(tracer)
          :erlang.raise(kind, reason, stacktrace)
      end
    after
      Context.restore(previous)
    end
  end

  def attach(tracer, fun) when is_pid(tracer) and is_function(fun, 0) do
    previous = Context.put(tracer)

    try do
      fun.()
    after
      Context.restore(previous)
    end
  end

  def current_tracer, do: Context.get()

  def trace(message, options \\ [])

  def trace(message, fun) when is_function(fun, 0), do: trace(message, [], fun)

  def trace(message, options) when is_list(options) do
    case tracer_from(options) do
      nil -> nil
      tracer -> unwrap(Tracer.line(tracer, message, options))
    end
  end

  def trace(message, options, fun) when is_list(options) and is_function(fun, 0) do
    case tracer_from(options) do
      nil ->
        fun.()

      tracer ->
        :ok = Tracer.begin_trace(tracer, message, options)

        try do
          result = fun.()

          :ok =
            unwrap(
              Tracer.end_trace(tracer, message, Keyword.get(options, :state, :success), result)
            )

          result
        catch
          kind, reason ->
            stacktrace = __STACKTRACE__
            _ = unwrap(Tracer.end_trace(tracer, message, :error, nil))
            :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  def tag(tag, options \\ []) do
    if tracer = tracer_from(options), do: unwrap(Tracer.tag(tracer, tag))
  end

  def artifact(name, path, options \\ []) do
    if tracer = tracer_from(options), do: unwrap(Tracer.artifact(tracer, name, path))
  end

  def fail(options \\ []), do: set_state(:error, options)
  def warn(options \\ []), do: set_state(:warning, options)
  def success(options \\ []), do: set_state(:success, options)

  def ignore(options \\ []) do
    if tracer = tracer_from(options), do: Tracer.ignore(tracer)
  end

  def wrapup(options \\ []) do
    case tracer_from(options) do
      nil -> nil
      tracer -> unwrap(Tracer.wrapup(tracer))
    end
  end

  def find(reference, options \\ []) do
    config = config_from(options)
    Driver.call(config.index_driver, :find, [reference])
  end

  def search(filters \\ []) do
    {config, filters} = Keyword.pop(filters, :config, configuration())
    config = normalize_config(config)
    Driver.call(config.index_driver, :search, [filters])
  end

  def payload(record, options \\ []) do
    config = config_from(options)
    Driver.call(config.data_driver, :read, [record])
  end

  def read_artifact(record, name, options \\ []) do
    config = config_from(options)
    Driver.call(config.data_driver, :read_artifact, [record, name])
  end

  defp set_state(state, options) do
    if tracer = tracer_from(options), do: Tracer.set_state(tracer, state)
  end

  defp tracer_from(options), do: Keyword.get(options, :tracer, current_tracer())

  defp config_from(options),
    do: options |> Keyword.get(:config, configuration()) |> normalize_config()

  defp normalize_config(%Configuration{} = config), do: config
  defp normalize_config(options) when is_list(options), do: Configuration.new(options)

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: raise(error)
  defp unwrap(value), do: value

  defp safely_record_failure(tracer, kind, reason) do
    message = failure_message(kind, reason)
    _ = trace("Exception: #{message}", state: :error, tracer: tracer)
    _ = fail(tracer: tracer)
  catch
    _, _ -> :ok
  end

  defp safely_wrapup(tracer) do
    _ = wrapup(tracer: tracer)
  catch
    _, _ -> :ok
  end

  defp failure_message(:error, reason) when is_exception(reason), do: Exception.message(reason)
  defp failure_message(_kind, reason), do: inspect(reason)

  defp ensure_started! do
    case Application.ensure_all_started(:trifle_traces) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise Trifle.Traces.Error, message: "failed to start trifle_traces: #{inspect(reason)}"
    end
  end
end
