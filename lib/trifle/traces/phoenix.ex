defmodule Trifle.Traces.Phoenix do
  @moduledoc """
  Phoenix endpoint integration driven by Telemetry lifecycle events.

  Add `{Trifle.Traces.Phoenix, options}` to the host supervision tree. The
  handler runs in the request process, so the current tracer is available to
  controller, LiveView mount, and downstream application code.
  """

  use GenServer

  alias Trifle.Traces.{Configuration, Context}

  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :endpoint, :exception]
  ]
  @context_key {__MODULE__, :request}

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

  def handle_event([:phoenix, :endpoint, :start], _measurements, metadata, options) do
    conn = metadata.conn

    if selected?(conn, options) do
      config =
        options
        |> Keyword.get(:config, Trifle.Traces.configuration())
        |> resolve(conn)
        |> normalize_config()

      key = options |> Keyword.get(:key, &default_key/1) |> resolve(conn)
      meta = options |> Keyword.get(:meta, &default_meta/1) |> resolve(conn)
      mode = options |> Keyword.get(:mode) |> resolve(conn)

      tracer_options =
        if mode, do: [config: config, meta: meta, mode: mode], else: [config: config, meta: meta]

      {:ok, tracer} = Trifle.Traces.start_tracer(key, tracer_options)
      previous = Context.put(tracer)
      Process.put(@context_key, {tracer, previous})
    end
  end

  def handle_event([:phoenix, :endpoint, :stop], measurements, metadata, _options) do
    finish(fn tracer ->
      status = metadata.conn.status || 200
      Trifle.Traces.trace("HTTP #{status}", [tracer: tracer], fn -> measurements end)
    end)
  end

  def handle_event([:phoenix, :endpoint, :exception], _measurements, metadata, _options) do
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

  defp selected?(conn, options),
    do: options |> Keyword.get(:selector, fn _ -> true end) |> resolve(conn)

  defp default_key(conn),
    do: "http/#{String.downcase(conn.method)}/#{String.trim_leading(conn.request_path, "/")}"

  defp default_meta(conn) do
    %{method: conn.method, request_path: conn.request_path, query_string: conn.query_string}
  end

  defp normalize_config(%Configuration{} = config), do: config
  defp normalize_config(options), do: Configuration.new(options)

  defp resolve(nil, _value), do: nil
  defp resolve(function, value) when is_function(function, 1), do: function.(value)
  defp resolve(value, _input), do: value

  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
