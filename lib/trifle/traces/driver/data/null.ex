defmodule Trifle.Traces.Driver.Data.Null do
  @moduledoc "No-op data driver used when payload persistence is disabled."
  @behaviour Trifle.Traces.Driver.Data

  defstruct []

  @impl true
  def generate_bucket_id(_driver), do: 0

  @impl true
  def write_part(_driver, _record, _part, _entries), do: :ok

  @impl true
  def write_artifact(_driver, _record, name, _options), do: name

  @impl true
  def read_part(_driver, _record, _part), do: []

  @impl true
  def read(_driver, _record), do: []

  @impl true
  def read_artifact(_driver, _record, _name), do: nil

  @impl true
  def delete(_driver, _record), do: nil
end
