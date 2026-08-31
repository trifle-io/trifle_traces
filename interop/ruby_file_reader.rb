# frozen_string_literal: true

ruby_repository, path = ARGV
$LOAD_PATH.unshift(File.join(ruby_repository, 'lib'))
require 'trifle/traces'

now = Time.now
record = Trifle::Traces::TraceRecord.new(
  reference: '01JELIXIR000000000000000', key: 'jobs/interop', state: :success,
  tags: [], meta: nil, context: {}, duration: 0,
  counters: Trifle::Traces::TraceRecord.empty_counters,
  length: 1, parts: 1, first_at: now, last_at: now,
  retention: 3, expires_at: now + (3 * 86_400), bucket_id: 0
)

driver = Trifle::Traces::Driver::Data::File.new(path: path)
entries = driver.read(record)

abort 'Ruby could not read the Elixir-generated payload' unless entries == [
  { at: 1_700_000_010, message: 'Elixir fixture', state: :success, type: :text, level: 0 }
]

unless driver.read_artifact(record, name: 'elixir.txt') == 'written by Elixir'
  abort 'Ruby could not read the Elixir-generated artifact'
end
