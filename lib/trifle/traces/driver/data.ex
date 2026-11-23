defmodule Trifle.Traces.Driver.Data do
  @moduledoc "Contract for trace payload and artifact drivers."

  alias Trifle.Traces.TraceRecord

  @callback generate_bucket_name(struct()) :: String.t() | nil
  @callback write_part(struct(), TraceRecord.t(), pos_integer(), [map()]) :: term()
  @callback write_artifact(struct(), TraceRecord.t(), String.t(), keyword()) :: term()
  @callback read_part(struct(), TraceRecord.t(), pos_integer()) :: [map()]
  @callback read(struct(), TraceRecord.t()) :: [map()]
  @callback read_artifact(struct(), TraceRecord.t(), String.t()) :: binary() | nil
  @callback delete(struct(), TraceRecord.t()) :: term()

  @doc "Stored size of an artifact in bytes, or nil when it does not exist."
  @callback artifact_size(struct(), TraceRecord.t(), String.t()) :: non_neg_integer() | nil

  @doc "Stored bytes `first..last` (inclusive) of an artifact, without reading the rest."
  @callback read_artifact_range(
              struct(),
              TraceRecord.t(),
              String.t(),
              non_neg_integer(),
              non_neg_integer()
            ) :: binary()

  # Drivers written before ranged reads keep working; Trifle.Traces falls back
  # to read_artifact/3 for them.
  @optional_callbacks artifact_size: 3, read_artifact_range: 5
end
