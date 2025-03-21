defmodule ExControlPlane.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_control_plane,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp aliases() do
    [
      test: "test --no-start"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExControlPlane.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.5"},
      {:envoy_xds, git: "https://github.com/proxyconf/envoy_xds_ex.git"},
      {:deep_merge, "~> 1.0"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
