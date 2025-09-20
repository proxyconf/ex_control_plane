defmodule RainbowPlane.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:ex_control_plane, :adapter_mod, RainbowPlane.ControlPlane)
    Application.ensure_all_started(:ex_control_plane)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: RainbowPlane.BanditSupervisor}
      # Starts a worker by calling: RainbowPlane.Worker.start_link(arg)
      # {RainbowPlane.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RainbowPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
