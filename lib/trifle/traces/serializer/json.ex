defmodule Trifle.Traces.Serializer.Json do
  @moduledoc "Serializes results as JSON."
  @behaviour Trifle.Traces.Serializer

  @impl true
  def sanitize(payload), do: Jason.encode!(payload)
end
