defmodule Trifle.Traces.IntegrationsTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Trifle.Traces.Configuration

  defp callback_config(parent) do
    Configuration.new(on_wrapup: fn tracer -> send(parent, {:trace, tracer}) end)
  end

  test "generic Plug wrapper traces a successful response" do
    conn = conn(:get, "/orders?state=open")

    response =
      Trifle.Traces.Plug.wrap(conn, [config: callback_config(self())], fn conn ->
        assert is_pid(Trifle.Traces.current_tracer())
        resp(conn, 201, "created")
      end)

    assert response.status == 201
    assert response.assigns.trifle_trace_reference
    assert_receive {:trace, snapshot}
    assert snapshot.key == "http/get/orders"
    assert snapshot.state == :success
    assert Enum.any?(snapshot.data, &(&1.message == "HTTP 201"))
  end

  test "generic Plug wrapper records and re-raises exceptions" do
    assert_raise RuntimeError, "plug failed", fn ->
      Trifle.Traces.Plug.wrap(conn(:get, "/fail"), [config: callback_config(self())], fn _conn ->
        raise "plug failed"
      end)
    end

    assert_receive {:trace, snapshot}
    assert snapshot.state == :error
  end

  test "Phoenix telemetry lifecycle binds and finalizes the tracer" do
    conn = conn(:get, "/dashboard") |> resp(200, "ok")
    options = [config: callback_config(self())]

    Trifle.Traces.Phoenix.handle_event([:phoenix, :endpoint, :start], %{}, %{conn: conn}, options)
    assert is_pid(Trifle.Traces.current_tracer())
    Trifle.Traces.trace("controller")

    Trifle.Traces.Phoenix.handle_event(
      [:phoenix, :endpoint, :stop],
      %{duration: 10},
      %{conn: conn},
      options
    )

    assert Trifle.Traces.current_tracer() == nil
    assert_receive {:trace, snapshot}
    assert snapshot.key == "http/get/dashboard"
    assert Enum.any?(snapshot.data, &(&1.message == "controller"))
  end

  test "Oban telemetry lifecycle derives job metadata and handles failure" do
    job = %{id: 10, queue: "default", worker: "MyApp.SyncWorker", attempt: 2, args: %{"id" => 42}}
    options = [config: callback_config(self())]

    Trifle.Traces.Oban.handle_event([:oban, :job, :start], %{}, %{job: job}, options)
    assert is_pid(Trifle.Traces.current_tracer())

    Trifle.Traces.Oban.handle_event(
      [:oban, :job, :exception],
      %{},
      %{job: job, reason: RuntimeError.exception("job failed")},
      options
    )

    assert Trifle.Traces.current_tracer() == nil
    assert_receive {:trace, snapshot}
    assert snapshot.key == "jobs/MyApp.SyncWorker"
    assert snapshot.meta.id == 10
    assert snapshot.state == :error
  end

  test "selectors skip Phoenix requests and Oban jobs" do
    options = [selector: fn _ -> false end, config: callback_config(self())]
    conn = conn(:get, "/skip")

    Trifle.Traces.Phoenix.handle_event([:phoenix, :endpoint, :start], %{}, %{conn: conn}, options)

    Trifle.Traces.Oban.handle_event(
      [:oban, :job, :start],
      %{},
      %{job: %{worker: "Skipped", id: 1, queue: "default", attempt: 1, args: %{}}},
      options
    )

    assert Trifle.Traces.current_tracer() == nil
    refute_receive {:trace, _}
  end

  test "telemetry integrations restore process context if a tracer disappears" do
    previous = spawn(fn -> Process.sleep(:infinity) end)
    Process.put({Trifle.Traces, :current_tracer}, previous)
    conn = conn(:get, "/dead")

    Trifle.Traces.Phoenix.handle_event(
      [:phoenix, :endpoint, :start],
      %{},
      %{conn: conn},
      config: callback_config(self())
    )

    tracer = Trifle.Traces.current_tracer()
    Process.exit(tracer, :kill)
    assert_eventually(fn -> not Process.alive?(tracer) end)

    assert catch_exit(
             Trifle.Traces.Phoenix.handle_event(
               [:phoenix, :endpoint, :stop],
               %{},
               %{conn: conn},
               []
             )
           )

    assert Trifle.Traces.current_tracer() == previous
    Process.exit(previous, :kill)
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
