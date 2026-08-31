# Changelog

## 2.0.0-rc.1 — unreleased

- Initial Elixir implementation of Trifle.Traces.
- Supervised, process-safe tracers with explicit Task propagation.
- Nested tracing, serializers, states, tags, artifacts, callbacks, and ignore semantics.
- Live and deferred persistence through Postgres, Mongo, S3, File, Memory, and Null drivers.
- PostgreSQL index driver with shared Ruby/Elixir JSONB schema, Ecto Repo reuse,
  indexed search, deterministic pagination, and scheduled retention cleanup.
- Ruby-compatible records, payload parts, search filters, cursors, retention, and counters.
- Phoenix, generic Plug, and Oban lifecycle integrations.
