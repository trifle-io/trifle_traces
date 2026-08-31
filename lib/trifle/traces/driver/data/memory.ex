defmodule Trifle.Traces.Driver.Data.Memory do
  @moduledoc "In-memory payload and artifact driver for development and tests."
  @behaviour Trifle.Traces.Driver.Data

  defstruct [:parts, :artifacts]

  def new do
    %__MODULE__{
      parts: :ets.new(__MODULE__.Parts, [:set, :public]),
      artifacts: :ets.new(__MODULE__.Artifacts, [:set, :public])
    }
  end

  @impl true
  def generate_bucket_id(_driver), do: 0

  @impl true
  def write_part(driver, record, part, entries) do
    true = :ets.insert(driver.parts, {{record.reference, part}, entries})
    :ok
  end

  @impl true
  def write_artifact(driver, record, name, options) do
    body = Keyword.get(options, :payload) || File.read!(Keyword.fetch!(options, :path))
    true = :ets.insert(driver.artifacts, {{record.reference, name}, body})
    name
  end

  @impl true
  def read_part(driver, record, part) do
    case :ets.lookup(driver.parts, {record.reference, part}) do
      [{{_, _}, entries}] -> entries
      [] -> raise KeyError, key: {record.reference, part}, term: driver.parts
    end
  end

  @impl true
  def read(driver, record) do
    if record.parts > 0 do
      Enum.flat_map(1..record.parts, &read_part(driver, record, &1))
    else
      []
    end
  end

  @impl true
  def read_artifact(driver, record, name) do
    case :ets.lookup(driver.artifacts, {record.reference, name}) do
      [{{_, _}, body}] -> body
      [] -> nil
    end
  end

  @impl true
  def delete(driver, record) do
    :ets.match_delete(driver.parts, {{record.reference, :_}, :_})
    :ets.match_delete(driver.artifacts, {{record.reference, :_}, :_})
    nil
  end
end
