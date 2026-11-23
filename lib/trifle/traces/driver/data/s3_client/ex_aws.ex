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
    # The size comes from a one-byte ranged GET rather than HEAD: ExAws's hackney
    # client does not handle the body-less reply hackney gives for HEAD.
    def object_size(config, bucket, key) do
      operation = ExAws.S3.get_object(bucket, key, range: "bytes=0-0")

      case ExAws.request(operation, limit_body(config, 1)) do
        {:ok, %{headers: headers}} ->
          total_size(headers) ||
            raise Trifle.Traces.Error, message: "S3 did not report the size of #{inspect(key)}"

        {:error, {:http_error, 404, _}} ->
          nil

        # An empty object has no first byte to return.
        {:error, {:http_error, 416, _}} ->
          0

        {:error, error} ->
          raise Trifle.Traces.Error, message: "S3 request failed: #{inspect(error)}"
      end
    end

    # "Content-Range: bytes 0-0/1234" carries the full size. An endpoint that
    # ignored the range answers 200, where Content-Length is the full size.
    defp total_size(headers) do
      case header(headers, "content-range") do
        nil ->
          with length when is_binary(length) <- header(headers, "content-length"),
               {size, ""} <- Integer.parse(length),
               do: size,
               else: (_ -> nil)

        range ->
          with [_, total] <- Regex.run(~r{/(\d+)\z}, range),
               do: String.to_integer(total),
               else: (_ -> nil)
      end
    end

    defp header(headers, wanted) do
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == wanted, do: to_string(value)
      end)
    end

    # The endpoint may ignore Range and answer with the whole object. max_body
    # stops hackney 1.x from buffering much beyond the requested length (newer
    # hackney ignores the option); the driver rejects any body that is not
    # exactly that long.
    @impl true
    def get_object_range(config, bucket, key, first, last) do
      response =
        bucket
        |> ExAws.S3.get_object(key, range: "bytes=#{first}-#{last}")
        |> request!(limit_body(config, last - first + 1))

      response.body
    end

    defp limit_body(config, bytes) when is_list(config) do
      Keyword.update(config, :http_opts, [max_body: bytes], &Keyword.put(&1, :max_body, bytes))
    end

    defp limit_body(config, _bytes), do: config

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
