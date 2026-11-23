defmodule Trifle.Traces.Driver.Data.S3 do
  @moduledoc "Stores payload parts and artifacts in S3-compatible object storage."
  @behaviour Trifle.Traces.Driver.Data

  alias Trifle.Traces.Driver.Data.Encoding

  defstruct adapter: Trifle.Traces.Driver.Data.S3Client.ExAws,
            client: [],
            buckets: [],
            prefix: "traces",
            gzip: false,
            max_part_bytes: nil,
            max_part_inflated_bytes: nil

  def new(options) do
    buckets = options |> Keyword.fetch!(:buckets) |> List.wrap()
    if buckets == [], do: raise(ArgumentError, "S3 driver requires at least one bucket")

    %__MODULE__{
      adapter: Keyword.get(options, :adapter, Trifle.Traces.Driver.Data.S3Client.ExAws),
      client: Keyword.get(options, :client, []),
      buckets: buckets,
      prefix: Keyword.get(options, :prefix, "traces"),
      gzip: Keyword.get(options, :gzip, false),
      max_part_bytes: Keyword.get(options, :max_part_bytes),
      max_part_inflated_bytes: Keyword.get(options, :max_part_inflated_bytes)
    }
  end

  def setup!(options) do
    driver = new(options)
    retentions = Keyword.fetch!(options, :retentions)

    rules =
      Enum.map(retentions, fn days ->
        %{
          id: "trifle-traces-#{days}d",
          enabled: true,
          filter: %{prefix: "#{days}/#{driver.prefix}/"},
          actions: %{expiration: %{trigger: {:days, days}}}
        }
      end)

    Enum.each(driver.buckets, &driver.adapter.put_lifecycle(driver.client, &1, rules))
    :ok
  end

  @impl true
  def generate_bucket_name(driver), do: Enum.random(driver.buckets)

  @impl true
  def write_part(driver, record, part, entries) do
    driver.adapter.put_object(
      driver.client,
      record.bucket_name,
      object_key(driver, record, Encoding.part_name(part, driver.gzip)),
      Encoding.pack_entries(entries, driver.gzip)
    )
  end

  @impl true
  def write_artifact(driver, record, name, options) do
    body = Keyword.get(options, :payload) || File.read!(Keyword.fetch!(options, :path))

    driver.adapter.put_object(
      driver.client,
      record.bucket_name,
      object_key(driver, record, "artifacts/#{name}"),
      body
    )

    name
  end

  @impl true
  def read_part(driver, record, part) do
    key = object_key(driver, record, Encoding.part_name(part, driver.gzip))

    driver
    |> part_body(record.bucket_name, key)
    |> Encoding.unpack_entries(driver.gzip, driver.max_part_inflated_bytes)
  end

  @impl true
  def read(driver, record) do
    if record.parts > 0,
      do: Enum.flat_map(1..record.parts, &read_part(driver, record, &1)),
      else: []
  end

  @impl true
  def read_artifact(driver, record, name) do
    driver.adapter.get_object(
      driver.client,
      record.bucket_name,
      object_key(driver, record, "artifacts/#{name}")
    )
  end

  @impl true
  def artifact_size(driver, record, name) do
    key = object_key(driver, record, "artifacts/#{name}")

    if ranged?(driver) do
      driver.adapter.object_size(driver.client, record.bucket_name, key)
    else
      case driver.adapter.get_object(driver.client, record.bucket_name, key) do
        body when is_binary(body) -> byte_size(body)
        _ -> nil
      end
    end
  end

  @impl true
  def read_artifact_range(driver, record, name, first, last) do
    key = object_key(driver, record, "artifacts/#{name}")

    if ranged?(driver) do
      driver.client
      |> driver.adapter.get_object_range(record.bucket_name, key, first, last)
      |> Encoding.exact!(name, first, last)
    else
      driver.client
      |> driver.adapter.get_object(record.bucket_name, key)
      |> Encoding.slice!(name, first, last)
    end
  end

  @impl true
  def delete(driver, record) do
    bucket = record.bucket_name
    prefix = object_key(driver, record, "")
    keys = driver.adapter.list_objects(driver.client, bucket, prefix)
    driver.adapter.delete_objects(driver.client, bucket, keys)
  end

  defp part_body(%{max_part_bytes: nil} = driver, bucket, key),
    do: driver.adapter.get_object(driver.client, bucket, key)

  # With a cap, the size is checked before the body is requested, and the body
  # is then fetched as an exact range so an endpoint cannot send more.
  defp part_body(driver, bucket, key) do
    if ranged?(driver) do
      size = driver.adapter.object_size(driver.client, bucket, key)

      unless is_integer(size) and size > 0,
        do: raise(Trifle.Traces.Error, message: "S3 object #{inspect(key)} is missing or empty")

      Encoding.check_part_size!(size, driver)

      driver.client
      |> driver.adapter.get_object_range(bucket, key, 0, size - 1)
      |> Encoding.exact!(key, 0, size - 1)
    else
      body = driver.adapter.get_object(driver.client, bucket, key)
      Encoding.check_part_size!(byte_size(body), driver)
      body
    end
  end

  # Adapters written before ranged reads only implement get_object/3.
  defp ranged?(driver) do
    Code.ensure_loaded?(driver.adapter) and
      function_exported?(driver.adapter, :object_size, 3) and
      function_exported?(driver.adapter, :get_object_range, 5)
  end

  defp object_key(driver, record, name) do
    "#{record.retention}/#{driver.prefix}/#{record.key}/#{record.reference}/#{name}"
  end
end
