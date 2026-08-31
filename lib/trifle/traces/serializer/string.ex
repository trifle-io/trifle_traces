defmodule Trifle.Traces.Serializer.String do
  @moduledoc "Serializes results with `String.Chars`."
  @behaviour Trifle.Traces.Serializer

  @impl true
  def sanitize(payload), do: to_string(payload)
end
