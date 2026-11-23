defmodule Trifle.Traces.Error do
  @moduledoc "An error raised by Trifle.Traces configuration or persistence."
  # `reason` is set for failures a caller may want to tell apart, e.g. :too_large.
  defexception [:message, :reason]
end
