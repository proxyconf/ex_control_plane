defmodule RainbowPlane.Examples.RoundRobin do
  alias ExControlPlane.Adapter.ClusterConfig
  alias RainbowPlane.Examples.Cluster
  alias RainbowPlane.Examples.Listener
  alias RainbowPlane.Examples.RouteConfiguration

  @doc """

    +-----------------+        +----------------------+        +------------------+
    |   Listener      |  -->   |   Route Table /      |  -->   |    Cluster(s)    |
    |  (port, filter) |        |   Virtual Hosts /    |        |  (upstream hosts)|
    |  (TCP/HTTP)     |        |   Routes (match ->)  |        |  (service pods)  |
    +-----------------+        +----------------------+        +------------------+
            |                          |   ^                             ^
            |                          |   |                             |
            |  Incoming connection     |   |                             |
            +--------------------------+   +-----------------------------+
  """

  def setup do
    %ClusterConfig{
      listeners: [Listener.default(8080)],
      route_configurations: [RouteConfiguration.default()],
      clusters: Cluster.from_color_servers()
    }
    |> RainbowPlane.ControlPlane.configure_deployment()
  end
end
