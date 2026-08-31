defmodule Trifle.Traces.TraceRecord do
  @moduledoc "Canonical trace metadata exchanged by tracers and persistence drivers."

  @states [:success, :warning, :error, :debug]
  @types [:text, :head, :raw, :media]

  @enforce_keys [:reference, :key]
  defstruct reference: nil,
            key: nil,
            state: :running,
            tags: [],
            meta: nil,
            context: %{},
            duration: 0,
            counters: %{},
            length: 0,
            parts: 0,
            first_at: nil,
            last_at: nil,
            retention: 7,
            expires_at: nil,
            bucket_id: 0

  @type t :: %__MODULE__{}

  def empty_counters do
    %{
      states: Map.new(@states, &{&1, 0}),
      types: Map.new(@types, &{&1, 0}),
      max_level: 0
    }
  end

  def segments(%__MODULE__{key: key}) do
    key
    |> to_string()
    |> String.split("/", trim: true)
    |> Enum.scan(fn part, prefix -> prefix <> "/" <> part end)
  end
end
