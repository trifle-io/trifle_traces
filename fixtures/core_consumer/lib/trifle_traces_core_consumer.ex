defmodule TrifleTracesCoreConsumer do
  @moduledoc false

  def trace(fun) do
    Trifle.Traces.with_tracer("core/consumer", fun)
  end
end
