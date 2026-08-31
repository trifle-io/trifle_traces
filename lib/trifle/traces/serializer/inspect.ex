defmodule Trifle.Traces.Serializer.Inspect do
  @moduledoc "Serializes results with `Kernel.inspect/1`."
  @behaviour Trifle.Traces.Serializer

  @impl true
  def sanitize(payload), do: inspect(payload)
end
