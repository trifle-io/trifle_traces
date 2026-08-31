defmodule Trifle.Traces.Serializer do
  @moduledoc "Behaviour implemented by trace result serializers."
  @callback sanitize(term()) :: String.t()
end
