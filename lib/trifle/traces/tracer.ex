defmodule Trifle.Traces.Tracer do
  @moduledoc "A supervised process that owns one execution trace."
  use GenServer

  alias Trifle.Traces.{Configuration, Dispatcher}

  @result_prefix "\u21B3 "
  @block_begin_suffix " \u21B4"
  @block_end_suffix " \u21B5"

  defstruct key: nil,
            meta: nil,
            config: nil,
            mode: :live,
            reference: nil,
            tags: [],
            data: [],
            artifacts: [],
            state: :running,
            ignore: false,
            levels: %{},
            monitors: %{},
            monitor_owners: %{},
            bumped_at: nil,
            dispatcher: nil

  @type t :: %__MODULE__{}

  def child_spec(options) do
    %{id: make_ref(), start: {__MODULE__, :start_link, [options]}, restart: :temporary}
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def line(pid, message, options \\ []),
    do: GenServer.call(pid, {:line, self(), message, options})

  def begin_trace(pid, message, options),
    do: GenServer.call(pid, {:begin_trace, self(), message, options})

  def end_trace(pid, message, state, result),
    do: GenServer.call(pid, {:end_trace, self(), message, state, result})

  def tag(pid, tag), do: GenServer.call(pid, {:tag, tag})
  def artifact(pid, name, path), do: GenServer.call(pid, {:artifact, name, path})
  def set_state(pid, state), do: GenServer.call(pid, {:state, state})
  def ignore(pid), do: GenServer.call(pid, :ignore)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def wrapup(pid), do: GenServer.call(pid, :wrapup, :infinity)

  def keys(%__MODULE__{key: key}) do
    key
    |> to_string()
    |> String.split("/", trim: true)
    |> Enum.scan(fn part, prefix -> prefix <> "/" <> part end)
  end

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    mode = options |> Keyword.get(:mode, config.default_mode) |> normalize_mode!()

    tracer = %__MODULE__{
      key: Keyword.fetch!(options, :key),
      meta: Keyword.get(options, :meta),
      config: config,
      mode: mode,
      reference: Keyword.get(options, :reference),
      bumped_at: System.monotonic_time(:millisecond)
    }

    tracer =
      add_entry(tracer, "Tracer has been initialized for #{tracer.key}", :success, :text, 0)

    {dispatcher, tracer} = Dispatcher.new(tracer)
    tracer = %{tracer | dispatcher: dispatcher}

    case persist(tracer, :liftoff, &Dispatcher.liftoff/2) do
      {:ok, tracer} ->
        run_callbacks(tracer, :liftoff)
        {:ok, tracer}

      {:error, error, _tracer} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:line, caller, message, options}, _from, tracer) do
    level = Map.get(tracer.levels, caller, 0)
    type = if Keyword.get(options, :head, false), do: :head, else: :text
    state = Keyword.get(options, :state, :success)
    tracer = add_entry(tracer, message, state, type, level)
    reply_after_bump(tracer, nil)
  end

  def handle_call({:begin_trace, caller, message, options}, _from, tracer) do
    level = Map.get(tracer.levels, caller, 0)
    type = if Keyword.get(options, :head, false), do: :head, else: :text
    state = Keyword.get(options, :state, :success)

    tracer =
      tracer
      |> monitor(caller)
      |> add_entry("#{message}#{@block_begin_suffix}", state, type, level)
      |> put_in([Access.key(:levels), caller], level + 1)

    {:reply, :ok, tracer}
  end

  def handle_call({:end_trace, caller, message, state, result}, _from, tracer) do
    level = max(Map.get(tracer.levels, caller, 1) - 1, 0)

    levels =
      if level == 0,
        do: Map.delete(tracer.levels, caller),
        else: Map.put(tracer.levels, caller, level)

    tracer =
      %{tracer | levels: levels}
      |> add_entry("#{message}#{@block_end_suffix}", state, :text, level)
      |> add_entry(
        "#{@result_prefix}#{sanitize(tracer.config.serializer, result)}",
        :success,
        :raw,
        level
      )
      |> maybe_demonitor(caller)

    reply_after_bump(tracer, :ok)
  end

  def handle_call({:tag, tag}, _from, tracer) do
    tracer = %{tracer | tags: tracer.tags ++ [tag]}
    reply_after_bump(tracer, tag)
  end

  def handle_call({:artifact, name, path}, _from, tracer) do
    size = File.stat!(path).size
    entry = %{at: now(), message: name, state: :success, type: :media, size: size}

    tracer = %{
      tracer
      | data: tracer.data ++ [entry],
        artifacts: tracer.artifacts ++ [%{name: name, path: path}]
    }

    reply_after_bump(tracer, path)
  end

  def handle_call({:state, state}, _from, tracer), do: {:reply, state, %{tracer | state: state}}
  def handle_call(:ignore, _from, tracer), do: {:reply, true, %{tracer | ignore: true}}
  def handle_call(:snapshot, _from, tracer), do: {:reply, public_snapshot(tracer), tracer}

  def handle_call(:wrapup, _from, tracer) do
    tracer = if tracer.state == :running, do: %{tracer | state: :success}, else: tracer

    case persist(tracer, :wrapup, &Dispatcher.wrapup/2) do
      {:ok, tracer} ->
        run_callbacks(tracer, :wrapup)
        snapshot = public_snapshot(tracer)
        {:stop, :normal, {:ok, snapshot}, tracer}

      {:error, error, tracer} ->
        {:reply, {:error, error}, tracer}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, caller, _reason}, tracer) do
    if tracer.monitors[caller] == reference do
      tracer = %{
        tracer
        | levels: Map.delete(tracer.levels, caller),
          monitors: Map.delete(tracer.monitors, caller),
          monitor_owners: Map.delete(tracer.monitor_owners, reference)
      }

      {:noreply, tracer}
    else
      {:noreply, tracer}
    end
  end

  defp reply_after_bump(tracer, reply) do
    interval = round(tracer.config.bump_every * 1_000)
    now = System.monotonic_time(:millisecond)

    if now - tracer.bumped_at >= interval do
      tracer = %{tracer | bumped_at: now}

      case persist(tracer, :bump, &Dispatcher.bump/2) do
        {:ok, tracer} ->
          run_callbacks(tracer, :bump)
          {:reply, reply, tracer}

        {:error, error, tracer} ->
          {:reply, {:error, error}, tracer}
      end
    else
      {:reply, reply, tracer}
    end
  end

  defp persist(tracer, phase, function) do
    try do
      {dispatcher, tracer} = function.(tracer.dispatcher, tracer)
      {:ok, %{tracer | dispatcher: dispatcher}}
    rescue
      error ->
        case tracer.config.error_handler.(error, public_snapshot(tracer), phase) do
          {:raise, replacement} -> {:error, replacement, tracer}
          :raise -> {:error, error, tracer}
          _ -> {:ok, tracer}
        end
    end
  end

  defp run_callbacks(tracer, event) do
    tracer.config
    |> Configuration.callbacks(event)
    |> Enum.each(& &1.(public_snapshot(tracer)))
  end

  defp add_entry(tracer, message, state, type, level) do
    entry = %{at: now(), message: to_string(message), state: state, type: type, level: level}
    %{tracer | data: tracer.data ++ [entry]}
  end

  defp sanitize(serializer, result) do
    serializer.sanitize(result)
  rescue
    _ -> Trifle.Traces.Serializer.Inspect.sanitize(result)
  end

  defp monitor(tracer, caller) do
    if Map.has_key?(tracer.monitors, caller) do
      tracer
    else
      reference = Process.monitor(caller)

      %{
        tracer
        | monitors: Map.put(tracer.monitors, caller, reference),
          monitor_owners: Map.put(tracer.monitor_owners, reference, caller)
      }
    end
  end

  defp maybe_demonitor(tracer, caller) do
    if Map.has_key?(tracer.levels, caller) do
      tracer
    else
      case Map.pop(tracer.monitors, caller) do
        {nil, _} ->
          tracer

        {reference, monitors} ->
          Process.demonitor(reference, [:flush])

          %{
            tracer
            | monitors: monitors,
              monitor_owners: Map.delete(tracer.monitor_owners, reference)
          }
      end
    end
  end

  defp public_snapshot(tracer) do
    %{tracer | monitors: %{}, monitor_owners: %{}, levels: %{}, dispatcher: nil}
  end

  defp normalize_mode!(mode) when mode in [:live, :deferred], do: mode
  defp normalize_mode!("live"), do: :live
  defp normalize_mode!("deferred"), do: :deferred
  defp normalize_mode!(mode), do: raise(ArgumentError, "invalid trace mode: #{inspect(mode)}")

  defp now, do: System.system_time(:second)
end
