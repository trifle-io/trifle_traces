defmodule Trifle.Traces.Driver.Data.S3Client do
  @moduledoc "Client contract used by the S3 data driver."

  @callback put_object(term(), String.t(), String.t(), binary()) :: term()
  @callback get_object(term(), String.t(), String.t()) :: binary()
  @callback list_objects(term(), String.t(), String.t()) :: [String.t()]
  @callback delete_objects(term(), String.t(), [String.t()]) :: term()
  @callback put_lifecycle(term(), String.t(), [map()]) :: term()
end
