defmodule RainbowPlane.Examples.StickySession do
  alias ExControlPlane.Adapter.ClusterConfig
  alias RainbowPlane.Examples.Cluster
  alias RainbowPlane.Examples.Listener
  alias RainbowPlane.Examples.RouteConfiguration
  alias RainbowPlane.Helpers

  def setup do
    %ClusterConfig{
      listeners: [Listener.default(8080) |> add_sticky_session_filter()],
      route_configurations: [RouteConfiguration.default()],
      clusters: Cluster.from_color_servers()
    }
    |> RainbowPlane.ControlPlane.configure_deployment()
  end

  defp add_sticky_session_filter(listener_config) do
    stateful_session_filter = %{
      "name" => "envoy.filters.http.stateful_session",
      "typed_config" => %{
        "@type" =>
          "type.googleapis.com/envoy.extensions.filters.http.stateful_session.v3.StatefulSession",
        "session_state" => %{
          "name" => "envoy.http.stateful_session.header",
          "typed_config" => %{
            "@type" =>
              "type.googleapis.com/envoy.extensions.http.stateful_session.header.v3.HeaderBasedSessionState",
            "name" => "rainbow-session"
          }
        }
      }
    }

    Helpers.patch(
      listener_config,
      :insert,
      ["filter_chains", 0, "filters", 0, "typed_config", "http_filters", 1],
      stateful_session_filter
    )
  end
end
