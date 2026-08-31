defmodule Trifle.Traces.Driver.Index do
  @moduledoc "Contract for searchable trace metadata drivers."

  alias Trifle.Traces.TraceRecord

  @type search_result :: %{traces: [TraceRecord.t()], cursor: String.t() | nil}

  @callback generate_reference(struct()) :: String.t()
  @callback capabilities(struct()) :: map()
  @callback create(struct(), TraceRecord.t()) :: term()
  @callback update(struct(), TraceRecord.t()) :: term()
  @callback delete(struct(), String.t()) :: term()
  @callback find(struct(), String.t()) :: TraceRecord.t() | nil
  @callback search(struct(), keyword()) :: search_result()
end
