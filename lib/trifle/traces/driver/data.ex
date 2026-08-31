defmodule Trifle.Traces.Driver.Data do
  @moduledoc "Contract for trace payload and artifact drivers."

  alias Trifle.Traces.TraceRecord

  @callback generate_bucket_id(struct()) :: non_neg_integer()
  @callback write_part(struct(), TraceRecord.t(), pos_integer(), [map()]) :: term()
  @callback write_artifact(struct(), TraceRecord.t(), String.t(), keyword()) :: term()
  @callback read_part(struct(), TraceRecord.t(), pos_integer()) :: [map()]
  @callback read(struct(), TraceRecord.t()) :: [map()]
  @callback read_artifact(struct(), TraceRecord.t(), String.t()) :: binary() | nil
  @callback delete(struct(), TraceRecord.t()) :: term()
end
