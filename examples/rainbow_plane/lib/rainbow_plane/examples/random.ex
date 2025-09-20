defmodule RainbowPlane.Examples.Random do
  alias ExControlPlane.Adapter.ClusterConfig
  alias RainbowPlane.Examples.Cluster
  alias RainbowPlane.Examples.Listener
  alias RainbowPlane.Examples.RouteConfiguration
  alias RainbowPlane.Helpers

  def setup do
    %ClusterConfig{
      listeners: [Listener.default(8080)],
      route_configurations: [RouteConfiguration.default()],
      clusters: Cluster.from_color_servers() |> enable_random_balancing()
    }
    |> RainbowPlane.ControlPlane.configure_deployment()
  end

  defp enable_random_balancing(clusters_config) do
    Helpers.patch(
      clusters_config,
      :update,
      [0, "lb_policy"],
      "RANDOM"
    )
  end
end
