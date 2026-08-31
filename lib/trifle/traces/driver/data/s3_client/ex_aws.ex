if Code.ensure_loaded?(ExAws) and Code.ensure_loaded?(ExAws.S3) do
  defmodule Trifle.Traces.Driver.Data.S3Client.ExAws do
    @moduledoc "Optional ExAws implementation of the S3 client contract."
    @behaviour Trifle.Traces.Driver.Data.S3Client

    @impl true
    def put_object(config, bucket, key, body) do
      bucket |> ExAws.S3.put_object(key, body) |> request!(config)
    end

    @impl true
    def get_object(config, bucket, key) do
      response = bucket |> ExAws.S3.get_object(key) |> request!(config)
      response.body
    end

    @impl true
    def list_objects(config, bucket, prefix) do
      response = bucket |> ExAws.S3.list_objects_v2(prefix: prefix) |> request!(config)
      Enum.map(response.body.contents || [], &(&1.key || &1["Key"]))
    end

    @impl true
    def delete_objects(_config, _bucket, []), do: :ok

    def delete_objects(config, bucket, keys) do
      bucket |> ExAws.S3.delete_all_objects(keys) |> request!(config)
    end

    @impl true
    def put_lifecycle(config, bucket, rules) do
      bucket |> ExAws.S3.put_bucket_lifecycle(rules) |> request!(config)
    end

    defp request!(operation, config) do
      case ExAws.request(operation, config) do
        {:ok, response} ->
          response

        {:error, error} ->
          raise Trifle.Traces.Error, message: "S3 request failed: #{inspect(error)}"
      end
    end
  end
end
