defmodule Trifle.Traces.Driver.Data.S3Client do
  @moduledoc "Client contract used by the S3 data driver."

  @callback put_object(term(), String.t(), String.t(), binary()) :: term()
  @callback get_object(term(), String.t(), String.t()) :: binary()
  @callback list_objects(term(), String.t(), String.t()) :: [String.t()]
  @callback delete_objects(term(), String.t(), [String.t()]) :: term()
  @callback put_lifecycle(term(), String.t(), [map()]) :: term()

  @doc "Object size in bytes, or nil when the object does not exist."
  @callback object_size(term(), String.t(), String.t()) :: non_neg_integer() | nil

  @doc "Bytes `first..last` (inclusive). Must not buffer much more than the requested length."
  @callback get_object_range(term(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
              binary()

  # Adapters written before ranged reads keep working; the S3 driver falls back
  # to get_object/3 for them.
  @optional_callbacks object_size: 3, get_object_range: 5
end
