defmodule RainbowPlane.Examples.Cluster do
  def from_color_servers do
    color_servers = RainbowPlane.ColorServers.get()

    [
      %{
        "name" => "color-servers",
        "connect_timeout" => "5s",
        "type" => "STRICT_DNS",
        "lb_policy" => "ROUND_ROBIN",
        "load_assignment" => %{
          "cluster_name" => "color-servers",
          "endpoints" => [
            %{
              "lb_endpoints" =>
                Enum.map(color_servers, fn %{port: port} ->
                  %{
                    "endpoint" => %{
                      "address" => %{
                        "socket_address" => %{
                          "address" => "127.0.0.1",
                          "port_value" => port
                        }
                      }
                    }
                  }
                end)
            }
          ]
        }
      }
    ]
  end
end
