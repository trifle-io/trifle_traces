alias Trifle.Traces.TraceRecord
alias Trifle.Traces.Driver.Data.File, as: FileDriver

[path] = System.argv()
now = DateTime.utc_now()

record = %TraceRecord{
  reference: "01JELIXIR000000000000000",
  key: "jobs/interop",
  state: :success,
  counters: TraceRecord.empty_counters(),
  parts: 1,
  retention: 3,
  first_at: now,
  last_at: now,
  expires_at: DateTime.add(now, 3, :day)
}

driver = FileDriver.new(path: path)
FileDriver.write_part(driver, record, 1, [
  %{at: 1_700_000_010, message: "Elixir fixture", state: :success, type: :text, level: 0}
])

FileDriver.write_artifact(driver, record, "elixir.txt", payload: "written by Elixir")
