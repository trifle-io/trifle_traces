alias Trifle.Traces.TraceRecord
alias Trifle.Traces.Driver.Index.Postgres, as: PostgresIndex

[postgres_url, table_name] = System.argv()
uri = URI.parse(postgres_url)
[username, password] = String.split(uri.userinfo, ":", parts: 2)

{:ok, connection} =
  Postgrex.start_link(
    hostname: uri.host,
    port: uri.port,
    username: username,
    password: password,
    database: String.trim_leading(uri.path, "/")
  )

driver = PostgresIndex.new(connection, table_name: table_name)
ruby_record = PostgresIndex.find(driver, "ruby-postgres-reference")

unless ruby_record.key == "jobs/interop/ruby" and ruby_record.state == :error and
         ruby_record.tags == ["source:ruby", "shared"] and
         ruby_record.meta == %{"writer" => "ruby"} and
         ruby_record.context == %{"tenant_id" => 42} and ruby_record.duration == 1_250 and
         ruby_record.counters.states.error == 1 and ruby_record.counters.max_level == 1 and
         ruby_record.bucket_id == 3 do
  raise "Elixir could not decode the Ruby-generated PostgreSQL record"
end

ruby_search =
  PostgresIndex.search(driver,
    segment: "jobs/interop",
    tags: %{any: ["missing", "source:ruby"], all: ["shared"]},
    state: :error,
    duration_min: 1_250
  )

unless Enum.map(ruby_search.traces, & &1.reference) == ["ruby-postgres-reference"] do
  raise "Elixir could not search the Ruby-generated PostgreSQL record"
end

first_at = ~U[2026-08-31 11:00:00Z]

elixir_record = %TraceRecord{
  reference: "elixir-postgres-reference",
  key: "jobs/interop/elixir",
  state: :warning,
  tags: ["source:elixir", "shared"],
  meta: %{"writer" => "elixir"},
  context: %{"tenant_id" => 84},
  duration: 2_500,
  counters: %{
    states: %{success: 1, warning: 1, error: 0, debug: 0},
    types: %{text: 1, head: 1, raw: 0, media: 0},
    max_level: 2
  },
  length: 2,
  parts: 2,
  first_at: first_at,
  last_at: DateTime.add(first_at, 2_500, :millisecond),
  retention: 30,
  expires_at: DateTime.add(first_at, 30, :day),
  bucket_id: 4
}

PostgresIndex.create(driver, elixir_record)
