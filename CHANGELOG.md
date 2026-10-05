# Changelog

## 2.0.0-rc.1 — unreleased

- Initial Elixir implementation of Trifle.Traces.
- Optional `stats_config` enables native activity Stats after successful wrapup
  for live and deferred traces, independently of callbacks. Disabled by default,
  with the same count/state/entry/duration payload as Ruby and Trifle App.
- Supervised, process-safe tracers with explicit Task propagation.
- Nested tracing, serializers, states, tags, artifacts, callbacks, and ignore semantics.
- Live and deferred persistence through Postgres, Mongo, S3, File, Memory, and Null drivers.
- Deferred traces skip liftoff and bump callbacks and run only wrapup callbacks,
  matching Ruby even when `bump_every` is zero.
- `Tracer.trace_record/1` exposes in-memory persistence metadata from an active
  PID or callback/final snapshot without reading the index.
- Explicit nil modes fall back to the configured default, matching Ruby.
- Uploaded artifact source files are removed after successful wrapup; failed
  writes retain files for retry and `cleanup: false` preserves reusable sources.
- S3 persists bucket names on trace records, keeping payload routing stable when
  the configured bucket list changes.
- PostgreSQL index driver with shared Ruby/Elixir JSONB schema, Ecto Repo reuse,
  indexed search, deterministic pagination, and scheduled retention cleanup.
- Ruby-compatible records, payload parts, search filters, cursors, retention, and counters.
- Phoenix, generic Plug, and Oban lifecycle integrations.
- Oban stores job arguments directly in `meta` (arrays or maps), matching Ruby
  integrations. Job ID, queue, worker and attempt live in `context`.
