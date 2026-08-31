defmodule Trifle.Traces.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Trifle.Traces.Configuration

  test "uses Ruby-compatible defaults without enabling persistence" do
    config = Configuration.new()

    assert config.bump_every == 15
    assert config.default_mode == :live
    assert config.payload_size_limit == 100 * 1024
    assert config.retention == 7
    refute config.persistence
  end

  test "captures callbacks and resolves dynamic context and retention" do
    callback = fn tracer -> tracer.key end

    config =
      Configuration.new(
        on_wrapup: callback,
        context: fn tracer -> %{key: tracer.key} end,
        retention: fn _tracer -> 30 end
      )

    tracer = %Trifle.Traces.Tracer{key: "jobs/import"}
    assert Configuration.callbacks(config, :wrapup) == [callback]
    assert Configuration.context_for(config, tracer) == %{key: "jobs/import"}
    assert Configuration.retention_for(config, tracer) == 30
  end

  test "rejects invalid options" do
    assert_raise ArgumentError, fn -> Configuration.new(default_mode: :streaming) end
    assert_raise ArgumentError, fn -> Configuration.new(bump_every: -1) end
    assert_raise ArgumentError, fn -> Configuration.new(payload_size_limit: 0) end

    assert_raise ArgumentError, fn ->
      Configuration.new(retention: 0) |> Configuration.retention_for(%{})
    end

    assert_raise ArgumentError, fn -> Configuration.new(unknown: true) end
  end

  test "keeps callbacks in registration order and accepts nil context" do
    first = fn _ -> :first end
    second = fn _ -> :second end

    config =
      Configuration.new(on_bump: first, context: fn _ -> nil end)
      |> Configuration.add_callback(:bump, second)

    assert Configuration.callbacks(config, :bump) == [first, second]
    assert Configuration.context_for(config, %{}) == %{}
  end
end
