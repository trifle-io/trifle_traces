defmodule Trifle.Traces.Dispatcher do
  @moduledoc false

  alias Trifle.Traces.{Driver, Ref, TraceRecord, Tracer}

  defstruct [:config, :record, :started_at, pending: [], pending_artifacts: []]

  def new(%Tracer{} = tracer) do
    validate_capabilities!(tracer)
    now = DateTime.utc_now()
    retention = tracer.config |> Trifle.Traces.Configuration.retention_for(tracer)
    reference = tracer.reference || Driver.call(tracer.config.index_driver, :generate_reference)

    record = %TraceRecord{
      reference: reference,
      key: tracer.key,
      state: tracer.state,
      tags: tracer.tags,
      meta: tracer.meta,
      context: Trifle.Traces.Configuration.context_for(tracer.config, tracer),
      duration: 0,
      counters: TraceRecord.empty_counters(),
      length: 0,
      parts: 0,
      first_at: now,
      last_at: now,
      retention: retention,
      expires_at: DateTime.add(now, retention, :day),
      bucket_id: Driver.call(tracer.config.data_driver, :generate_bucket_id)
    }

    {%__MODULE__{
       config: tracer.config,
       record: record,
       started_at: System.monotonic_time(:millisecond)
     }, %{tracer | reference: reference}}
  end

  def liftoff(dispatcher, tracer) do
    if persistence?(dispatcher) and live?(tracer) do
      {dispatcher, tracer} = drain(dispatcher, tracer)
      {dispatcher, tracer} = write_part(dispatcher, tracer)
      Driver.call(dispatcher.config.index_driver, :create, [dispatcher.record])
      {dispatcher, tracer}
    else
      {dispatcher, tracer}
    end
  end

  def bump(dispatcher, tracer) do
    if persistence?(dispatcher) and live?(tracer) do
      {dispatcher, tracer} = drain(dispatcher, tracer)

      if dispatcher.pending == [] and dispatcher.pending_artifacts == [] do
        {dispatcher, tracer}
      else
        {dispatcher, tracer} = write_part(dispatcher, tracer)
        Driver.call(dispatcher.config.index_driver, :update, [dispatcher.record])
        {dispatcher, tracer}
      end
    else
      {dispatcher, tracer}
    end
  end

  def wrapup(dispatcher, %Tracer{ignore: true} = tracer), do: ignore_wrapup(dispatcher, tracer)

  def wrapup(dispatcher, tracer) do
    if persistence?(dispatcher) do
      dispatcher = sync_record(dispatcher, tracer)
      {dispatcher, tracer} = drain(dispatcher, tracer)

      {dispatcher, tracer} =
        if dispatcher.pending == [] and dispatcher.pending_artifacts == [] do
          {dispatcher, tracer}
        else
          write_part(dispatcher, tracer)
        end

      function = if live?(tracer), do: :update, else: :create
      Driver.call(dispatcher.config.index_driver, function, [dispatcher.record])
      {dispatcher, tracer}
    else
      {dispatcher, tracer}
    end
  end

  defp persistence?(dispatcher), do: dispatcher.config.persistence
  defp live?(tracer), do: tracer.mode == :live

  defp validate_capabilities!(%Tracer{config: %{persistence: false}}), do: :ok
  defp validate_capabilities!(%Tracer{mode: :deferred}), do: :ok

  defp validate_capabilities!(tracer) do
    capabilities = Driver.call(tracer.config.index_driver, :capabilities)

    unless capabilities[:update] do
      raise Trifle.Traces.Error,
        message:
          "#{inspect(Driver.module(tracer.config.index_driver))} does not support update; " <>
            "use mode: :deferred"
    end
  end

  defp drain(dispatcher, tracer) do
    {
      %{
        dispatcher
        | pending: dispatcher.pending ++ tracer.data,
          pending_artifacts: dispatcher.pending_artifacts ++ tracer.artifacts
      },
      %{tracer | data: [], artifacts: []}
    }
  end

  defp write_part(dispatcher, tracer) do
    part = dispatcher.record.parts + 1
    dispatcher = offload_pending(dispatcher)
    dispatcher = upload_artifacts(dispatcher)

    Driver.call(dispatcher.config.data_driver, :write_part, [
      dispatcher.record,
      part,
      dispatcher.pending
    ])

    record =
      dispatcher.record
      |> Map.update!(:length, &(&1 + length(dispatcher.pending)))
      |> accumulate_counters(dispatcher.pending)
      |> Map.put(:parts, part)

    dispatcher = %{dispatcher | record: record} |> sync_record(tracer)
    {%{dispatcher | pending: []}, tracer}
  end

  defp upload_artifacts(dispatcher) do
    Enum.each(dispatcher.pending_artifacts, fn artifact ->
      Driver.call(dispatcher.config.data_driver, :write_artifact, [
        dispatcher.record,
        artifact.name,
        [path: artifact.path]
      ])
    end)

    %{dispatcher | pending_artifacts: []}
  end

  defp offload_pending(dispatcher) do
    pending =
      Enum.map(dispatcher.pending, fn entry ->
        message = stringify(entry.message)

        if byte_size(message) > dispatcher.config.payload_size_limit do
          name = "part_row_#{Ref.generate() |> String.downcase()}.txt"

          Driver.call(dispatcher.config.data_driver, :write_artifact, [
            dispatcher.record,
            name,
            [payload: message]
          ])

          entry
          |> Map.put(:message, name)
          |> Map.put(:type, :media)
          |> Map.put(:size, byte_size(message))
        else
          entry
        end
      end)

    %{dispatcher | pending: pending}
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp sync_record(dispatcher, tracer) do
    duration =
      max(dispatcher.record.duration, System.monotonic_time(:millisecond) - dispatcher.started_at)

    record = %{
      dispatcher.record
      | state: tracer.state,
        tags: tracer.tags |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        last_at: DateTime.utc_now(),
        duration: duration
    }

    %{dispatcher | record: record}
  end

  defp accumulate_counters(record, entries) do
    counters =
      Enum.reduce(entries, record.counters, fn entry, counters ->
        counters
        |> increment_in(:states, entry[:state])
        |> increment_in(:types, entry[:type])
        |> Map.update!(:max_level, &max(&1, Map.get(entry, :level, 0)))
      end)

    %{record | counters: counters}
  end

  defp increment_in(counters, group, key) do
    if Map.has_key?(counters[group], key) do
      update_in(counters, [group, key], &(&1 + 1))
    else
      counters
    end
  end

  defp ignore_wrapup(dispatcher, tracer) do
    if persistence?(dispatcher) and live?(tracer) do
      capabilities = Driver.call(dispatcher.config.index_driver, :capabilities)

      if capabilities[:delete] do
        Driver.call(dispatcher.config.index_driver, :delete, [dispatcher.record.reference])
      end

      try do
        Driver.call(dispatcher.config.data_driver, :delete, [dispatcher.record])
      rescue
        _ -> :ok
      end
    end

    {dispatcher, tracer}
  end
end
