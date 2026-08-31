defmodule TrifleTracesCoreConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :trifle_traces_core_consumer,
      version: "0.0.0",
      elixir: "~> 1.15",
      deps: [{:trifle_traces, path: "../.."}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
