defmodule RainbowPlane.Examples.RouteConfiguration do
  def default(route_config_name \\ "default-route-config") do
    %{
      "name" => route_config_name,
      "virtual_hosts" => [
        %{
          "name" => "default",
          "domains" => ["*"],
          "routes" => [
            %{
              "name" => "default-route",
              "match" => %{
                "prefix" => "/"
              },
              "route" => %{
                "cluster" => "color-servers"
              }
            }
          ]
        }
      ],
      "typed_per_filter_config" => %{
        "envoy.filters.http.cors" => %{
          "@type" => "type.googleapis.com/envoy.extensions.filters.http.cors.v3.CorsPolicy",
          "allow_origin_string_match" => [
            %{"exact" => "http://localhost:8080"},
            # the null origin is sent by the script embedded in the iframe content (??)
            %{"exact" => "null"}
          ],
          "allow_methods" => "GET,POST,OPTIONS",
          "allow_headers" => "rainbow-session",
          "expose_headers" => "rainbow-session",
          "max_age" => "3600"
        }
      }
    }
  end
end
