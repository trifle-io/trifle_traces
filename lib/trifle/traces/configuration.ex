defmodule Trifle.Traces.Configuration do
  @moduledoc "Validated configuration captured by each tracer when it starts."

  require Logger

  alias Trifle.Traces.Driver.Data.Null, as: NullData
  alias Trifle.Traces.Driver.Index.Null, as: NullIndex

  defstruct serializer: Trifle.Traces.Serializer.Inspect,
            index_driver: %NullIndex{},
            data_driver: %NullData{},
            persistence: false,
            callbacks: %{liftoff: [], bump: [], wrapup: []},
            bump_every: 15,
            default_mode: :live,
            payload_size_limit: 100 * 1024,
            error_handler: nil,
            context: %{},
            retention: 7

  @type t :: %__MODULE__{}

  def new(options \\ []) when is_list(options) do
    defaults = %__MODULE__{error_handler: &default_error_handler/3}

    explicit_persistence =
      Keyword.has_key?(options, :index_driver) or Keyword.has_key?(options, :data_driver)

    config =
      Enum.reduce(options, defaults, fn
        {:on_liftoff, callback}, acc ->
          add_callback(acc, :liftoff, callback)

        {:on_bump, callback}, acc ->
          add_callback(acc, :bump, callback)

        {:on_wrapup, callback}, acc ->
          add_callback(acc, :wrapup, callback)

        {key, value}, acc when is_map_key(acc, key) ->
          Map.put(acc, key, value)

        {key, _value}, _acc ->
          raise ArgumentError, "unknown Trifle.Traces option: #{inspect(key)}"
      end)
      |> Map.put(:persistence, explicit_persistence)

    validate!(config)
  end

  def add_callback(%__MODULE__{} = config, event, callback)
      when event in [:liftoff, :bump, :wrapup] and is_function(callback, 1) do
    update_in(config.callbacks[event], &(&1 ++ [callback]))
  end

  def context_for(%__MODULE__{context: context}, tracer), do: resolve(context, tracer) || %{}

  def retention_for(%__MODULE__{retention: retention}, tracer) do
    case resolve(retention, tracer) do
      days when is_integer(days) and days > 0 ->
        days

      value ->
        raise ArgumentError,
              "retention must resolve to a positive integer, got: #{inspect(value)}"
    end
  end

  def callbacks(%__MODULE__{} = config, event), do: Map.fetch!(config.callbacks, event)

  defp resolve(value, tracer) when is_function(value, 1), do: value.(tracer)
  defp resolve(value, _tracer), do: value

  defp validate!(%__MODULE__{default_mode: mode}) when mode not in [:live, :deferred] do
    raise ArgumentError, "default_mode must be :live or :deferred"
  end

  defp validate!(%__MODULE__{bump_every: seconds}) when not is_number(seconds) or seconds < 0 do
    raise ArgumentError, "bump_every must be a non-negative number"
  end

  defp validate!(%__MODULE__{payload_size_limit: bytes})
       when not is_integer(bytes) or bytes < 1 do
    raise ArgumentError, "payload_size_limit must be a positive integer"
  end

  defp validate!(config), do: config

  defp default_error_handler(error, _tracer, :bump) do
    Logger.warning(
      "Trifle.Traces bump persistence failed; pending data will retry: " <>
        Exception.format_banner(:error, error)
    )

    :ok
  end

  defp default_error_handler(error, _tracer, _phase), do: {:raise, error}
end
