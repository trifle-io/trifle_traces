defmodule TrifleTracesCoreConsumerTest do
  use ExUnit.Case

  test "runs the tracing core without optional clients" do
    assert TrifleTracesCoreConsumer.trace(fn ->
             Trifle.Traces.trace("core-only")
             :ok
           end) == :ok

    refute Code.ensure_loaded?(Mongo)
    refute Code.ensure_loaded?(Postgrex)
    refute Code.ensure_loaded?(Plug.Conn)
    refute Code.ensure_loaded?(Oban.Job)
    refute Code.ensure_loaded?(ExAws)
  end
end
