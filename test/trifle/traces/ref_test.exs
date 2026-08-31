defmodule Trifle.Traces.RefTest do
  use ExUnit.Case, async: true

  alias Trifle.Traces.Ref

  test "generates unique, sortable Crockford Base32 references" do
    first = Ref.generate(~U[2026-01-01 00:00:00Z])
    second = Ref.generate(~U[2026-01-01 00:00:01Z])
    references = Enum.map(1..1_000, fn _ -> Ref.generate() end)

    assert first =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/
    assert first < second
    assert Enum.uniq(references) == references
    assert references == Enum.sort(references)
  end
end
