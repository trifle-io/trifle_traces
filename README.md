# Trifle.Traces

[![Elixir CI](https://github.com/trifle-io/trifle_traces/actions/workflows/elixir.yml/badge.svg)](https://github.com/trifle-io/trifle_traces/actions/workflows/elixir.yml)

Structured execution tracing for Elixir. Capture the complete flow of a job,
request, or integration—including nested return values, decisions, errors,
tags, and artifacts—and persist it through searchable index and payload
drivers.

This repository is the Elixir counterpart of
[Trifle::Traces](https://github.com/trifle-io/trifle-traces). Version 2.0 uses
the same PostgreSQL schema, Mongo documents, and File/S3 payload format in both
languages.

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
{:postgrex, "~> 0.17"}
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

With automated persistence, uploaded artifact source files are removed after
final payload and index writes succeed at wrapup, before wrapup callbacks. Live
uploads and failed wrapups retain files until then. Use
`Trifle.Traces.artifact(name, path, cleanup: false)` to keep reusable sources.
Callback-only setups, Null data drivers, and direct driver writes retain sources.
Cleanup errors are logged; termination before wrapup can leave files behind.

## Configuration

```elixir
config =
  Trifle.Traces.configure(
    index_driver: Trifle.Traces.Driver.Index.Postgres.new(MyApp.Repo),
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
Trifle.Traces.Driver.Index.Postgres.setup!(MyApp.Repo)

Trifle.Traces.Driver.Data.S3.setup!(
  buckets: ["traces-a", "traces-b"],
  retentions: [3, 7, 30, 90]
)

# Run periodically from Oban or another scheduler:
Trifle.Traces.Driver.Index.Postgres.cleanup!(MyApp.Repo)
```

The Postgres driver accepts either a Postgrex connection or an Ecto Repo that
exports `query!/3`. Passing the application Repo reuses its existing pool.

## Activity Stats

Add `{:trifle_stats, "~> 2.0"}` to your application, configure Stats normally,
and pass that configuration to Traces:

```elixir
stats_config = Trifle.Stats.Configuration.configure(
  Trifle.Stats.Driver.Mongo.new(:mongo, "trifle_traces_stats"),
  time_zone: "Etc/UTC",
  track_granularities: ["10m", "1h", "1d"],
  buffer_enabled: false
)

Trifle.Traces.configure(
  index_driver: index_driver,
  data_driver: data_driver,
  stats_config: stats_config
)
```

Provision the Stats driver's indexes once before starting workers. `stats_config`
defaults to `nil`; global Stats is not used implicitly. The supplied configuration
owns storage, granularities, timezone, week start and buffering.

The SDK tracks the full trace key after successful wrapup for live and deferred
traces, before user callbacks, using finalized counts and millisecond duration
without another index query. Values include `count`, `states.<state>`,
`entries.count`, duration count/sum/square and per-state duration samples, matching
Ruby and Trifle App. Ignored traces and failed final writes emit no metrics.
Stats failures are logged without failing the trace; callbacks stay independent.
Tracking also works without persistence drivers, retaining callback data.
See [configuration](https://docs.trifle.io/trifle-traces-ex/configuration#activity-metrics).

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
  part and one final index record. It skips liftoff and bump callbacks, even
  with `bump_every: 0`, and runs only wrapup callbacks.

```elixir
Trifle.Traces.with_tracer("jobs/high-volume", [mode: :deferred], fn ->
  # work
end)
```

With persistence configured, callbacks receive the dispatcher's in-memory
metadata as `tracer.trace_record`, without querying the index. At successful
wrapup this includes final `duration` in milliseconds, `length`, `parts`,
`counters`, `tags`, and `bucket_name`:

```elixir
on_wrapup: fn tracer ->
  unless tracer.ignore do
    record = Trifle.Traces.Tracer.trace_record(tracer)
    Metrics.trace_finished(record.key, record.duration, record.length)
  end
end
```

`Trifle.Traces.Tracer.trace_record/1` also accepts an active tracer PID. It
reflects the last persistence operation, so a deferred trace has no persisted
entries until wrapup. Callback and final snapshots retain this immutable record
after the tracer process stops. Without persistence drivers, use the snapshot's
`data` for accumulated entries.

Available index drivers: Postgres, Mongo, Memory, and Null. Available data
drivers: S3, File, Memory, and Null. Database and object-storage clients are
optional and injected by the host application.

S3 selects a bucket once per trace and persists its name as `bucket_name` in the
index. Reads, writes, and deletes use that name directly, so changing the bucket
list does not redirect existing traces. File, Memory, and Null store `nil`.

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
  {Trifle.Traces.Oban,
   selector: fn job -> job.queue != "discardable" end,
   mode: fn job -> if job.worker == "MyApp.CalculateWorker", do: :deferred, else: :live end},
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

The mode is selected when execution starts, so current handler configuration
also applies to already queued jobs. A missing or nil mode falls back to
`config.default_mode`.

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
