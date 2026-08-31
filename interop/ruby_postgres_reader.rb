# frozen_string_literal: true

ruby_repository, postgres_url, table_name = ARGV
$LOAD_PATH.unshift(File.join(ruby_repository, 'lib'))

require 'pg'
require 'trifle/traces'

client = PG.connect(postgres_url)
driver = Trifle::Traces::Driver::Index::Postgres.new(client, table_name: table_name)
record = driver.find('elixir-postgres-reference')

valid = record.key == 'jobs/interop/elixir' &&
        record.state == :warning &&
        record.tags == ['source:elixir', 'shared'] &&
        record.meta == { 'writer' => 'elixir' } &&
        record.context == { 'tenant_id' => 84 } &&
        record.duration == 2_500 &&
        record.counters[:states][:warning] == 1 &&
        record.counters[:max_level] == 2 &&
        record.bucket_id == 4
abort 'Ruby could not decode the Elixir-generated PostgreSQL record' unless valid

result = driver.search(
  segment: 'jobs/interop',
  tags: { any: ['missing', 'source:elixir'], all: ['shared'] },
  state: :warning,
  duration_min: 2_500
)

unless result[:traces].map(&:reference) == ['elixir-postgres-reference']
  abort 'Ruby could not search the Elixir-generated PostgreSQL record'
end

client.exec("DROP TABLE #{driver.table_name}")
client.close
