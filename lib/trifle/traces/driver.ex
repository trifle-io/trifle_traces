defmodule Trifle.Traces.Driver do
  @moduledoc false

  def module(%module{}), do: module

  def call(driver, function, arguments \\ []) do
    apply(module(driver), function, [driver | arguments])
  end
end
