alias Trifle.Traces.TraceRecord
alias Trifle.Traces.Driver.Data.File, as: FileDriver

[path] = System.argv()

record = %TraceRecord{
  reference: "01JRUBY00000000000000000",
  key: "jobs/interop",
  parts: 1,
  retention: 3
}

driver = FileDriver.new(path: path)

expected = [
  %{at: 1_700_000_020, message: "Ruby generated", state: :warning, type: :head, level: 1}
]

unless FileDriver.read(driver, record) == expected do
  raise "Elixir could not read the Ruby-generated payload"
end

unless FileDriver.read_artifact(driver, record, "ruby.txt") == "written by Ruby" do
  raise "Elixir could not read the Ruby-generated artifact"
end
