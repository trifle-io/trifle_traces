# frozen_string_literal: true

ruby_repository, postgres_url, table_name = ARGV
$LOAD_PATH.unshift(File.join(ruby_repository, 'lib'))

require 'pg'
require 'trifle/traces'

client = PG.connect(postgres_url)
driver_class = Trifle::Traces::Driver::Index::Postgres
client.exec("DROP TABLE IF EXISTS #{driver_class.validate_table_name!(table_name)}")
driver_class.setup!(client, table_name: table_name)
driver = driver_class.new(client, table_name: table_name)

first_at = Time.utc(2026, 8, 31, 10, 0, 0)
record = Trifle::Traces::TraceRecord.new(
  reference: 'ruby-postgres-reference',
  key: 'jobs/interop/ruby',
  state: :error,
  tags: ['source:ruby', 'shared'],
  meta: { writer: 'ruby' },
  context: { tenant_id: 42 },
  duration: 1_250,
  counters: {
    states: { success: 1, warning: 0, error: 1, debug: 0 },
    types: { text: 2, head: 0, raw: 0, media: 0 },
    max_level: 1
  },
  length: 2,
  parts: 1,
  first_at: first_at,
  last_at: first_at + 1.25,
  retention: 7,
  expires_at: first_at + (7 * 86_400),
  bucket_id: 3
)

driver.create(record)
client.close
