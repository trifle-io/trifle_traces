# Trifle.Traces

[![Elixir CI](https://github.com/trifle-io/trifle_traces/actions/workflows/elixir.yml/badge.svg)](https://github.com/trifle-io/trifle_traces/actions/workflows/elixir.yml)

Structured execution tracing for Elixir. Capture the complete flow of a job,
request, or integration—including nested return values, decisions, errors,
tags, and artifacts—and persist it through searchable index and payload
drivers.

This repository is the Elixir counterpart of
[Trifle::Traces](https://github.com/trifle-io/trifle-traces). Version 2.0 uses
the same Mongo documents and File/S3 payload format in both languages.

> **Release candidate:** `2.0.0-rc.1` is prepared for Git installation and
> coordinated compatibility testing. It is not published on Hex.

## Installation

Add the Git dependency to `mix.exs`:

```elixir
def deps do
  [
    {:trifle_traces,
     github: "trifle-io/trifle_traces",
     tag: "v2.0.0-rc.1"}
  ]
end
```

Add only the optional clients used by your application. For example:

```elixir
{:mongodb_driver, "~> 1.2"}
{:ex_aws, "~> 2.5"}
{:ex_aws_s3, "~> 2.5"}
{:hackney, "~> 4.0"}
{:sweet_xml, "~> 0.7"}
{:plug, "~> 1.15"}
{:oban, "~> 2.17"}
```

## Quick start

```elixir
Trifle.Traces.with_tracer("jobs/orders/sync", fn ->
  Trifle.Traces.tag("store:42")
  Trifle.Traces.trace("Loading orders", head: true)

  orders =
    Trifle.Traces.trace("GET /orders", fn ->
      Orders.fetch_all()
    end)

  Enum.each(orders, fn order ->
    Trifle.Traces.trace("Processing order #{order.id}")
  end)
end)
```

Without persistence drivers, trace data remains in the final tracer snapshot
received by callbacks. Block tracing remains transparent when no tracer is
active: the function still runs and its result is returned.

## Configuration

```elixir
{:ok, mongo} = Mongo.start_link(url: "mongodb://localhost:27017/trifle")

config =
  Trifle.Traces.configure(
    index_driver: Trifle.Traces.Driver.Index.Mongo.new(mongo),
    data_driver: Trifle.Traces.Driver.Data.S3.new(
      buckets: ["traces-a", "traces-b"],
      prefix: "traces",
      gzip: true
    ),
    bump_every: 15,
    default_mode: :live,
    retention: fn tracer -> if String.starts_with?(tracer.key, "audit/"), do: 90, else: 7 end,
    context: fn tracer ->
      meta = tracer.meta || %{}
      %{source: meta[:source] || meta["source"]}
    end,
    on_wrapup: fn tracer -> IO.inspect({tracer.reference, tracer.state}) end
  )
```

Run driver setup explicitly during provisioning:

```elixir
Trifle.Traces.Driver.Index.Mongo.setup!(mongo)

Trifle.Traces.Driver.Data.S3.setup!(
  buckets: ["traces-a", "traces-b"],
  retentions: [3, 7, 30, 90]
)
```

## Current tracer and Tasks

The concise API uses a process-local tracer binding. BEAM processes do not
inherit process dictionary values, so propagate the explicit tracer handle
when work moves into a Task:

```elixir
tracer = Trifle.Traces.current_tracer()

Task.async(fn ->
  Trifle.Traces.attach(tracer, fn ->
    Trifle.Traces.trace("Running concurrently")
  end)
end)
|> Task.await()
```

Multiple Tasks can share one tracer safely. Nesting depth is isolated per
calling process.

## Persistence modes

- `:live` creates the index record at liftoff and flushes numbered payload
  parts as the trace runs.
- `:deferred` performs no storage I/O before wrapup, then writes one payload
  part and one final index record.

```elixir
Trifle.Traces.with_tracer("jobs/high-volume", [mode: :deferred], fn ->
  # work
end)
```

Available index drivers: Mongo, Memory, and Null. Available data drivers: S3,
File, Memory, and Null. Database and object-storage clients are optional and
injected by the host application.

## Reading persisted traces

```elixir
record = Trifle.Traces.find(reference)

page =
  Trifle.Traces.search(
    segment: "jobs/orders",
    tags: %{any: ["store:42", "store:43"], all: ["billing"]},
    state: :error,
    from: ~U[2026-08-01 00:00:00Z],
    to: ~U[2026-09-01 00:00:00Z],
    duration_min: 5_000,
    limit: 50
  )

entries = Trifle.Traces.payload(record)
binary = Trifle.Traces.read_artifact(record, "report.csv")
```

## Web and job integrations

Phoenix endpoint tracing uses Telemetry and sees both successful requests and
exceptions:

```elixir
children = [
  {Trifle.Traces.Phoenix, []},
  MyAppWeb.Endpoint
]
```

For a generic Plug endpoint, use `Trifle.Traces.Plug.wrap/3`. The module also
implements a normal Plug for successful-response lifecycle tracing.

Oban uses the same lifecycle pattern:

```elixir
children = [
  {Trifle.Traces.Oban, selector: fn job -> job.queue != "discardable" end},
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

## Development

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test --cover
mix docs
mix hex.build
```

`mix hex.build` validates the archive locally. The project does not create or
publish a Hex package.

Coordinated Git-tag releases are documented in [RELEASING.md](RELEASING.md).

Full documentation lives at
[docs.trifle.io/trifle-traces-ex](https://docs.trifle.io/trifle-traces-ex).

## License

Trifle.Traces is available under the MIT License.
