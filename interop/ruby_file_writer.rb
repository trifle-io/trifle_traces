# frozen_string_literal: true

ruby_repository, path = ARGV
$LOAD_PATH.unshift(File.join(ruby_repository, 'lib'))
require 'trifle/traces'

now = Time.now
record = Trifle::Traces::TraceRecord.new(
  reference: '01JRUBY00000000000000000', key: 'jobs/interop', state: :success,
  tags: [], meta: nil, context: {}, duration: 0,
  counters: Trifle::Traces::TraceRecord.empty_counters,
  length: 1, parts: 1, first_at: now, last_at: now,
  retention: 3, expires_at: now + (3 * 86_400), bucket_id: 0
)

driver = Trifle::Traces::Driver::Data::File.new(path: path)
driver.write_part(
  record,
  part: 1,
  entries: [
    { at: 1_700_000_020, message: 'Ruby generated', state: :warning, type: :head, level: 1 }
  ]
)
driver.write_artifact(record, name: 'ruby.txt', payload: 'written by Ruby')
