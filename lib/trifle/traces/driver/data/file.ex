defmodule Trifle.Traces.Driver.Data.File do
  @moduledoc "Stores trace payload parts and artifacts on a local filesystem."
  @behaviour Trifle.Traces.Driver.Data

  alias Trifle.Traces.Driver.Data.Encoding

  defstruct [:path, gzip: false]

  def new(options) do
    %__MODULE__{path: Keyword.fetch!(options, :path), gzip: Keyword.get(options, :gzip, false)}
  end

  def setup!(options) do
    options |> Keyword.fetch!(:path) |> File.mkdir_p!()
    :ok
  end

  def cleanup!(%__MODULE__{} = driver, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    driver.path
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(fn retention_dir ->
      with {days, ""} when days > 0 <- Integer.parse(Path.basename(retention_dir)) do
        cutoff = DateTime.add(now, -days, :day)

        retention_dir
        |> Path.join("**/data_1.json*")
        |> Path.wildcard()
        |> Enum.map(&Path.dirname/1)
        |> Enum.uniq()
        |> Enum.each(fn trace_dir ->
          stat = File.stat!(trace_dir, time: :posix)
          if stat.mtime < DateTime.to_unix(cutoff), do: File.rm_rf!(trace_dir)
        end)
      else
        _ -> :ok
      end
    end)

    :ok
  end

  @impl true
  def generate_bucket_id(_driver), do: 0

  @impl true
  def write_part(driver, record, part, entries) do
    write(
      driver,
      record,
      Encoding.part_name(part, driver.gzip),
      Encoding.pack_entries(entries, driver.gzip)
    )
  end

  @impl true
  def write_artifact(driver, record, name, options) do
    body = Keyword.get(options, :payload) || File.read!(Keyword.fetch!(options, :path))
    write(driver, record, Path.join("artifacts", name), body)
    name
  end

  @impl true
  def read_part(driver, record, part) do
    driver
    |> file_path(record, Encoding.part_name(part, driver.gzip))
    |> File.read!()
    |> Encoding.unpack_entries(driver.gzip)
  end

  @impl true
  def read(driver, record) do
    if record.parts > 0,
      do: Enum.flat_map(1..record.parts, &read_part(driver, record, &1)),
      else: []
  end

  @impl true
  def read_artifact(driver, record, name),
    do: File.read!(file_path(driver, record, Path.join("artifacts", name)))

  @impl true
  def delete(driver, record), do: File.rm_rf(trace_dir(driver, record))

  defp write(driver, record, name, body) do
    target = file_path(driver, record, name)
    target |> Path.dirname() |> File.mkdir_p!()
    File.write!(target, body)
  end

  defp file_path(driver, record, name), do: Path.join(trace_dir(driver, record), name)

  defp trace_dir(driver, record) do
    Path.join([
      driver.path,
      to_string(record.retention),
      to_string(record.key),
      to_string(record.reference)
    ])
  end
end
