defmodule Trifle.Traces.InteropFixtureTest do
  use ExUnit.Case, async: true

  alias Trifle.Traces.TraceRecord
  alias Trifle.Traces.Driver.Data.File, as: FileDriver

  test "reads the canonical Ruby payload and artifact layout" do
    root = Path.expand("../../fixtures/ruby", __DIR__)
    driver = FileDriver.new(path: root)

    record = %TraceRecord{
      reference: "01JRBTRACE0000000000000000",
      key: "jobs/interop",
      parts: 1,
      retention: 3
    }

    assert FileDriver.read(driver, record) == [
             %{
               at: 1_700_000_000,
               message: "Ruby fixture",
               state: :success,
               type: :text,
               level: 0
             },
             %{at: 1_700_000_001, message: "Ruby warning", state: :warning, type: :head, level: 1}
           ]

    assert FileDriver.read_artifact(driver, record, "report.txt") == "written by Ruby\n"
  end
end
