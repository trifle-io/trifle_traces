defmodule Trifle.Traces.Oban do
  @moduledoc """
  Oban integration driven by job Telemetry events.

  Add `{Trifle.Traces.Oban, options}` to the host supervision tree. All jobs
  are traced by default; pass `selector: fn job -> ... end` to opt out.
  """

  use GenServer

  alias Trifle.Traces.{Configuration, Context}

  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]
  @context_key {__MODULE__, :job}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    id = Keyword.get(options, :handler_id, {__MODULE__, self()})
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, options)
    {:ok, %{handler_id: id}}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  def handle_event([:oban, :job, :start], _measurements, metadata, options) do
    job = metadata.job

    if selected?(job, options) do
      config =
        options
        |> Keyword.get(:config, Trifle.Traces.configuration())
        |> resolve(job)
        |> normalize_config()

      key = options |> Keyword.get(:key, &default_key/1) |> resolve(job)
      meta = options |> Keyword.get(:meta, &default_meta/1) |> resolve(job)
      mode = options |> Keyword.get(:mode) |> resolve(job)

      tracer_options =
        if mode, do: [config: config, meta: meta, mode: mode], else: [config: config, meta: meta]

      {:ok, tracer} = Trifle.Traces.start_tracer(key, tracer_options)
      previous = Context.put(tracer)
      Process.put(@context_key, {tracer, previous})
    end
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _options) do
    finish(fn tracer ->
      Trifle.Traces.trace("Oban job completed", [tracer: tracer], fn ->
        %{measurements: measurements, state: metadata[:state]}
      end)
    end)
  end

  def handle_event([:oban, :job, :exception], _measurements, metadata, _options) do
    finish(fn tracer ->
      reason = metadata[:reason] || metadata[:error]
      Trifle.Traces.trace("Exception: #{message(reason)}", state: :error, tracer: tracer)
      Trifle.Traces.fail(tracer: tracer)
    end)
  end

  defp finish(before_wrapup) do
    case Process.delete(@context_key) do
      {tracer, previous} ->
        try do
          try do
            before_wrapup.(tracer)
          after
            safe_wrapup(tracer)
          end
        after
          Context.restore(previous)
        end

      nil ->
        :ok
    end
  end

  defp safe_wrapup(tracer) do
    Trifle.Traces.wrapup(tracer: tracer)
  catch
    _, _ -> :ok
  end

  defp selected?(job, options),
    do: options |> Keyword.get(:selector, fn _ -> true end) |> resolve(job)

  defp default_key(job) do
    worker = field(job, :worker) |> to_string() |> String.trim_leading("Elixir.")
    "jobs/#{worker}"
  end

  defp default_meta(job) do
    Map.new([:id, :queue, :worker, :attempt, :args], fn key -> {key, field(job, key)} end)
  end

  defp field(job, key), do: Map.get(job, key, Map.get(job, to_string(key)))

  defp normalize_config(%Configuration{} = config), do: config
  defp normalize_config(options), do: Configuration.new(options)

  defp resolve(nil, _value), do: nil
  defp resolve(function, value) when is_function(function, 1), do: function.(value)
  defp resolve(value, _input), do: value

  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
