defmodule ExControlPlane.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        ExControlPlane.Snapshot.Supervisor,
        DynamicSupervisor.child_spec(name: ExControlPlane.StreamSupervisor),
        Registry.child_spec(keys: :unique, name: ExControlPlane.StreamRegistry),
        ExControlPlane.ConfigCache,
        {GRPC.Server.Supervisor,
         [
           {:endpoint, ExControlPlane.Endpoint},
           {:port, Application.get_env(:ex_control_plane, :grpc_endpoint_port, 18000)},
           {:start_server, Application.get_env(:ex_control_plane, :grpc_start_server, true)}
           | Application.get_env(:ex_control_plane, :grpc_server_opts, [])
         ]}
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExControlPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
