defmodule ExControlPlane.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/proxyconf/ex_control_plane"

  def project do
    [
      app: :ex_control_plane,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Test coverage
      test_coverage: [summary: [threshold: 70]],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],

      # Hex.pm package
      name: "ExControlPlane",
      description: "Elixir implementation of an Envoy xDS Control Plane with ADS support",
      source_url: @source_url,
      homepage_url: "https://proxyconf.com/docs/ex-control-plane/",
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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

  defp package do
    [
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["ProxyConf Team"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.5"},
      {:envoy_xds, git: "https://github.com/proxyconf/envoy_xds_ex.git"},
      {:deep_merge, "~> 1.0"},

      # Dev/Test dependencies
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:finch, "~> 0.18", only: :test},
      {:jason, "~> 1.4", only: :test}
    ]
  end
end
