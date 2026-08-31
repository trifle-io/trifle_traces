defmodule Trifle.Traces.Driver.Index.Null do
  @moduledoc "No-op index driver used when metadata persistence is disabled."
  @behaviour Trifle.Traces.Driver.Index

  defstruct []

  @impl true
  def generate_reference(_driver), do: Trifle.Traces.Ref.generate()

  @impl true
  def capabilities(_driver), do: %{update: true, delete: true, search: false, ttl: :none}

  @impl true
  def create(_driver, record), do: record.reference

  @impl true
  def update(_driver, record), do: record.reference

  @impl true
  def delete(_driver, _reference), do: nil

  @impl true
  def find(_driver, _reference), do: nil

  @impl true
  def search(_driver, _filters), do: %{traces: [], cursor: nil}
end
