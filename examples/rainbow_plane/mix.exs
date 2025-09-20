defmodule RainbowPlane.MixProject do
  use Mix.Project

  def project do
    [
      app: :rainbow_plane,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {RainbowPlane.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:ex_control_plane, git: "https://github.com/proxyconf/ex_control_plane.git", runtime: false},
      {:ex_control_plane, path: "../..", runtime: false},
      {:bandit, "~> 1.8"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
