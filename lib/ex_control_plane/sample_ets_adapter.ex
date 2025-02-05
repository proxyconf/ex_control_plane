defmodule ExControlPlane.SampleEtsAdapter do
  @behaviour ExControlPlane.Adapter

  def init do
    :ets.new(__MODULE__, [:named_table, :public])
  end

  def insert_sample(cluster, api_id) do
    :ets.insert(
      __MODULE__,
      {{cluster, api_id},
       %ExControlPlane.Adapter.ApiConfig{
         api_id: api_id,
         cluster: cluster,
         hash: :crypto.strong_rand_bytes(10),
         config: %{}
       }}
    )

    ExControlPlane.ConfigCache.load_events(cluster, [{:updated, api_id}])
  end

  def get_api_config(tid, cluster_id, api_id) do
    case :ets.lookup(tid, {cluster_id, api_id}) do
      [{_, config}] -> {:ok, config}
      [] -> {:error, "not_found"}
    end
  end

  def map_reduce(tid, mapper_fn, acc) do
    :ets.foldl(
      fn {_, config}, {results, acc} ->
        {map_res, acc} = mapper_fn.(config, acc)
        {map_res ++ results, acc}
      end,
      {[], acc},
      tid
    )
  end

  def generate_resources(_tid, _cluster_id, _changes) do
    from_oas3 = routes_from_oas3()

    %ExControlPlane.Adapter.ClusterConfig{
      listeners: [
        %{
          "address" => %{
            "socket_address" => %{
              "address" => "0.0.0.0",
              "port_value" => 8080
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
                    "http_filters" => [
                      %{
                        "name" => "envoy.filters.http.router",
                        "typed_config" => %{
                          "@type" =>
                            "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"
                        }
                      }
                    ],
                    "route_config" => %{
                      "name" => "httpbin_route",
                      "virtual_hosts" => [
                        %{
                          "name" => "httpbin",
                          "domains" => ["*"],
                          "routes" => from_oas3.routes
                        }
                      ]
                    }
                  }
                }
              ]
            }
          ]
        }
      ],
      clusters: from_oas3.clusters
    }
  end

  defp routes_from_oas3 do
    oas3 = %{
      "openapi" => "3.0.3",
      "info" => %{},
      "servers" => [%{"url" => "https://httpbin.org"}],
      "paths" => %{
        "/{requestPath}" => %{
          "get" => %{
            "responses" => %{
              "200" => %{
                "content" => "application/json"
              }
            }
          },
          "post" => %{
            "requestBody" => %{
              "content" => %{"application/json" => %{}}
            },
            "responses" => %{
              "200" => %{
                "content" => %{"application/json" => %{}}
              }
            }
          }
        }
      }
    }

    {routes, clusters} = ExControlPlane.OpenapiTransform.transform("sample-api", "/test", oas3)
    %{routes: routes, clusters: clusters_from_oas3_transform(clusters)}
  end

  defp clusters_from_oas3_transform(clusters) do
    Enum.map(
      clusters,
      fn {cluster_name, cluster_uri} ->
        %{
          "name" => cluster_name,
          "connect_timeout" => "5s",
          "type" => "STRICT_DNS",
          "lb_policy" => "ROUND_ROBIN",
          "transport_socket" => %{
            "name" => "envoy.transport_sockets.tls",
            "typed_config" => %{
              "@type" =>
                "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext",
              "sni" => cluster_uri.host
            }
          },
          "load_assignment" => %{
            "cluster_name" => cluster_name,
            "endpoints" => [
              %{
                "lb_endpoints" => [
                  %{
                    "endpoint" => %{
                      "address" => %{
                        "socket_address" => %{
                          "address" => cluster_uri.host,
                          "port_value" => cluster_uri.port
                        }
                      }
                    }
                  }
                ]
              }
            ]
          }
        }
      end
    )
  end
end
