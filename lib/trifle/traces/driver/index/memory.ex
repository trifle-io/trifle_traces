defmodule Trifle.Traces.Driver.Index.Memory do
  @moduledoc "In-memory index driver for development and tests."
  @behaviour Trifle.Traces.Driver.Index

  alias Trifle.Traces.Driver.Index.Query

  defstruct [:table]

  def new do
    %__MODULE__{table: :ets.new(__MODULE__, [:set, :public])}
  end

  @impl true
  def generate_reference(_driver), do: Trifle.Traces.Ref.generate()

  @impl true
  def capabilities(_driver), do: %{update: true, delete: true, search: true, ttl: :none}

  @impl true
  def create(driver, record) do
    true = :ets.insert(driver.table, {record.reference, record})
    record.reference
  end

  @impl true
  def update(driver, record), do: create(driver, record)

  @impl true
  def delete(driver, reference) do
    :ets.delete(driver.table, reference)
    nil
  end

  @impl true
  def find(driver, reference) do
    case :ets.lookup(driver.table, reference) do
      [{^reference, record}] -> record
      [] -> nil
    end
  end

  @impl true
  def search(driver, filters) do
    limit = Query.limit(filters)
    cursor = Query.decode_cursor(Keyword.get(filters, :cursor))

    traces =
      driver.table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&Query.matches?(&1, filters))
      |> Enum.filter(&Query.after_cursor?(&1, cursor))
      |> Query.sort()
      |> Enum.take(limit)

    next_cursor = if length(traces) == limit, do: Query.encode_cursor(List.last(traces))
    %{traces: traces, cursor: next_cursor}
  end
end
