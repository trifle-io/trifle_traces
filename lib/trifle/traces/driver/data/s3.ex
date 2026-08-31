defmodule Trifle.Traces.Driver.Data.S3 do
  @moduledoc "Stores payload parts and artifacts in S3-compatible object storage."
  @behaviour Trifle.Traces.Driver.Data

  alias Trifle.Traces.Driver.Data.Encoding

  defstruct adapter: Trifle.Traces.Driver.Data.S3Client.ExAws,
            client: [],
            buckets: [],
            prefix: "traces",
            gzip: false

  def new(options) do
    buckets = options |> Keyword.fetch!(:buckets) |> List.wrap()
    if buckets == [], do: raise(ArgumentError, "S3 driver requires at least one bucket")

    %__MODULE__{
      adapter: Keyword.get(options, :adapter, Trifle.Traces.Driver.Data.S3Client.ExAws),
      client: Keyword.get(options, :client, []),
      buckets: buckets,
      prefix: Keyword.get(options, :prefix, "traces"),
      gzip: Keyword.get(options, :gzip, false)
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
  def generate_bucket_id(driver), do: :rand.uniform(length(driver.buckets)) - 1

  @impl true
  def write_part(driver, record, part, entries) do
    driver.adapter.put_object(
      driver.client,
      bucket_for(driver, record),
      object_key(driver, record, Encoding.part_name(part, driver.gzip)),
      Encoding.pack_entries(entries, driver.gzip)
    )
  end

  @impl true
  def write_artifact(driver, record, name, options) do
    body = Keyword.get(options, :payload) || File.read!(Keyword.fetch!(options, :path))

    driver.adapter.put_object(
      driver.client,
      bucket_for(driver, record),
      object_key(driver, record, "artifacts/#{name}"),
      body
    )

    name
  end

  @impl true
  def read_part(driver, record, part) do
    driver.adapter.get_object(
      driver.client,
      bucket_for(driver, record),
      object_key(driver, record, Encoding.part_name(part, driver.gzip))
    )
    |> Encoding.unpack_entries(driver.gzip)
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
      bucket_for(driver, record),
      object_key(driver, record, "artifacts/#{name}")
    )
  end

  @impl true
  def delete(driver, record) do
    bucket = bucket_for(driver, record)
    prefix = object_key(driver, record, "")
    keys = driver.adapter.list_objects(driver.client, bucket, prefix)
    driver.adapter.delete_objects(driver.client, bucket, keys)
  end

  defp bucket_for(driver, record),
    do: Enum.at(driver.buckets, rem(record.bucket_id, length(driver.buckets)))

  defp object_key(driver, record, name) do
    "#{record.retention}/#{driver.prefix}/#{record.key}/#{record.reference}/#{name}"
  end
end
