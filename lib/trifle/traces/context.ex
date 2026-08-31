defmodule Trifle.Traces.Context do
  @moduledoc false

  @process_key {Trifle.Traces, :current_tracer}

  def get, do: Process.get(@process_key)

  def put(tracer) do
    previous = get()
    Process.put(@process_key, tracer)
    previous
  end

  def restore(nil), do: Process.delete(@process_key)
  def restore(previous), do: Process.put(@process_key, previous)
end
