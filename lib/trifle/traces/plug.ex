if Code.ensure_loaded?(Plug.Conn) do
  defmodule Trifle.Traces.Plug do
    @moduledoc """
    Plug integration for request tracing.

    `call/2` starts a trace and finalizes it before the response is sent. For a
    generic Plug endpoint that must also capture downstream exceptions, wrap the
    endpoint with `wrap/3`. Phoenix applications should prefer
    `Trifle.Traces.Phoenix`, which follows the complete endpoint lifecycle.
    """

    import Plug.Conn

    alias Trifle.Traces.{Configuration, Context, Tracer}

    def init(options), do: options

    def call(conn, options) do
      if selected?(conn, options) do
        {conn, tracer, previous} = start(conn, options)

        register_before_send(conn, fn conn ->
          finish(conn, tracer, previous)
        end)
      else
        conn
      end
    end

    def wrap(conn, options, next) when is_function(next, 1) do
      if selected?(conn, options) do
        {conn, tracer, previous} = start(conn, options)

        conn =
          try do
            next.(conn)
          catch
            kind, reason ->
              stacktrace = __STACKTRACE__
              record_exception(tracer, kind, reason)
              safe_wrapup(tracer)
              Context.restore(previous)
              :erlang.raise(kind, reason, stacktrace)
          end

        finish(conn, tracer, previous)
      else
        next.(conn)
      end
    end

    defp start(conn, options) do
      config = resolve(Keyword.get(options, :config, Trifle.Traces.configuration()), conn)
      key = resolve(Keyword.get(options, :key, &default_key/1), conn)
      meta = resolve(Keyword.get(options, :meta, &default_meta/1), conn)
      mode = resolve(Keyword.get(options, :mode), conn)

      tracer_options = [config: normalize_config(config), meta: meta]
      tracer_options = if mode, do: Keyword.put(tracer_options, :mode, mode), else: tracer_options
      {:ok, tracer} = Trifle.Traces.start_tracer(key, tracer_options)
      reference = Tracer.snapshot(tracer).reference
      previous = Context.put(tracer)

      conn =
        conn
        |> assign(:trifle_trace_reference, reference)
        |> put_private(:trifle_traces_tracer, tracer)

      {conn, tracer, previous}
    end

    defp finish(conn, tracer, previous) do
      try do
        if Process.alive?(tracer) do
          try do
            Trifle.Traces.trace("HTTP #{conn.status || 200}", tracer: tracer)
          after
            safe_wrapup(tracer)
          end
        end
      after
        Context.restore(previous)
      end

      conn
    end

    defp record_exception(tracer, kind, reason) do
      Trifle.Traces.trace("Exception: #{exception_message(kind, reason)}",
        state: :error,
        tracer: tracer
      )

      Trifle.Traces.fail(tracer: tracer)
    end

    defp safe_wrapup(tracer) do
      Trifle.Traces.wrapup(tracer: tracer)
    catch
      _, _ -> :ok
    end

    defp selected?(conn, options),
      do: resolve(Keyword.get(options, :selector, fn _ -> true end), conn)

    defp default_key(conn),
      do: "http/#{String.downcase(conn.method)}/#{String.trim_leading(conn.request_path, "/")}"

    defp default_meta(conn) do
      %{
        method: conn.method,
        request_path: conn.request_path,
        query_string: conn.query_string,
        request_id: List.first(get_req_header(conn, "x-request-id"))
      }
    end

    defp normalize_config(%Configuration{} = config), do: config
    defp normalize_config(options), do: Configuration.new(options)

    defp resolve(nil, _value), do: nil
    defp resolve(function, value) when is_function(function, 1), do: function.(value)
    defp resolve(value, _input), do: value

    defp exception_message(:error, reason) when is_exception(reason),
      do: Exception.message(reason)

    defp exception_message(_kind, reason), do: inspect(reason)
  end
end
