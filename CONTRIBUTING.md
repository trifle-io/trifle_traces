# Contributing

Install the versions from `.tool-versions`, then run:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test --cover
mix docs
mix hex.build
```

Mongo and S3-compatible integration tests use the local services in
`.devops/docker/local_db`:

```sh
docker compose -f .devops/docker/local_db/docker-compose.yml up -d
MONGO_URL=mongodb://localhost:27017/trifle_traces_test \
S3_ENDPOINT=http://localhost:9000 mix test --include integration
```

Changes to persisted records or payloads must pass the Ruby/Elixir
interoperability fixtures and be coordinated with `trifle-io/trifle-traces`.

See `RELEASING.md` for the coordinated Git-tag release process. This project
does not publish to Hex.
