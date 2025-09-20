defmodule RainbowPlane.Examples.Listener do
  def default(port, route_config_name \\ "default-route-config") do
    %{
      "address" => %{
        "socket_address" => %{
          "address" => "0.0.0.0",
          "port_value" => port
        }
      },
      "filter_chains" => [
        %{
          "filters" => [
            %{
              "name" => "envoy.filters.network.http_connection_manager",
              "typed_config" => %{
                "@type" =>
                  "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                "stat_prefix" => "ingress_http",
                "rds" => %{
                  "config_source" => %{
                    "ads" => %{},
                    "resource_api_version" => "V3"
                  },
                  "route_config_name" => route_config_name
                },
                "http_filters" => [
                  %{
                    "name" => "envoy.filters.http.cors",
                    "typed_config" => %{
                      "@type" => "type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors"
                    }
                  },
                  %{
                    "name" => "envoy.filters.http.router",
                    "typed_config" => %{
                      "@type" =>
                        "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router",
                      "suppress_envoy_headers" => true
                    }
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end
end
