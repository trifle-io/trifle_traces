defmodule Trifle.Traces.Stats do
  @moduledoc false

  require Logger

  def track(_record, nil), do: :ok

  def track(record, config) do
    state = to_string(record.state)
    sample = %{count: 1, sum: record.duration, square: record.duration * record.duration}

    values = %{
      count: 1,
      states: %{state => 1},
      entries: %{count: record.length},
      duration: Map.put(sample, :states, %{state => sample})
    }

    # Stats is optional; core-only consumers do not need it installed.
    apply(Trifle.Stats, :track, [to_string(record.key), record.last_at, values, config])
    :ok
  rescue
    error ->
      Logger.warning(
        "Trifle.Traces trace=#{record.reference} stats tracking failed: " <>
          Exception.format_banner(:error, error)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Trifle.Traces trace=#{record.reference} stats tracking failed: #{kind}: #{inspect(reason)}"
      )

      :ok
  end
end
