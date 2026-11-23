defmodule Trifle.Traces.Driver.Data.File do
  @moduledoc "Stores trace payload parts and artifacts on a local filesystem."
  @behaviour Trifle.Traces.Driver.Data

  alias Trifle.Traces.Driver.Data.Encoding

  defstruct [:path, gzip: false, max_part_bytes: nil, max_part_inflated_bytes: nil]

  def new(options) do
    %__MODULE__{
      path: Keyword.fetch!(options, :path),
      gzip: Keyword.get(options, :gzip, false),
      max_part_bytes: Keyword.get(options, :max_part_bytes),
      max_part_inflated_bytes: Keyword.get(options, :max_part_inflated_bytes)
    }
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
  def generate_bucket_name(_driver), do: nil

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
    path = file_path(driver, record, Encoding.part_name(part, driver.gzip))
    if driver.max_part_bytes, do: Encoding.check_part_size!(File.stat!(path).size, driver)

    path
    |> File.read!()
    |> Encoding.unpack_entries(driver.gzip, driver.max_part_inflated_bytes)
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
  def artifact_size(driver, record, name) do
    case File.stat(file_path(driver, record, Path.join("artifacts", name))) do
      {:ok, %{type: :regular, size: size}} -> size
      _ -> nil
    end
  end

  @impl true
  def read_artifact_range(driver, record, name, first, last) do
    path = file_path(driver, record, Path.join("artifacts", name))

    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          case :file.pread(file, first, last - first + 1) do
            {:ok, body} -> Encoding.exact!(body, name, first, last)
            :eof -> Encoding.exact!("", name, first, last)
            {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: path
    end
  end

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
