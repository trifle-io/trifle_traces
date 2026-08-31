defmodule Trifle.Traces.MixProject do
  use Mix.Project

  @version "2.0.0-rc.1"
  @source_url "https://github.com/trifle-io/trifle_traces"

  def project do
    [
      app: :trifle_traces,
      version: @version,
      name: "Trifle.Traces",
      description: "Structured execution tracing for Elixir jobs, requests, and integrations.",
      source_url: @source_url,
      homepage_url: "https://trifle.io",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Trifle.Traces.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:mongodb_driver, "~> 1.2.0", optional: true},
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:hackney, "~> 4.0", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},
      {:plug, "~> 1.14", optional: true},
      {:oban, "~> 2.17", optional: true},
      {:ex_doc, "~> 0.31.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "RELEASING.md", "LICENSE"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://docs.trifle.io/trifle-traces-ex"
      }
    ]
  end

  defp docs do
    [
      main: "Trifle.Traces",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
