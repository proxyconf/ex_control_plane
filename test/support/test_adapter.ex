defmodule ExControlPlane.TestAdapter do
  @moduledoc """
  A minimal adapter for integration testing with real Envoy.

  This adapter generates valid xDS resources that Envoy can consume.
  Tests can configure specific resources via `set_config/2`.
  """
  @behaviour ExControlPlane.Adapter

  alias ExControlPlane.Adapter.{ApiConfig, ClusterConfig}

  @table __MODULE__
  @config_table :test_adapter_config

  @impl true
  def init do
    # Create tables if they don't exist
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public])
    end

    if :ets.whereis(@config_table) == :undefined do
      :ets.new(@config_table, [:named_table, :public])
    end

    @table
  end

  @doc """
  Sets a custom ClusterConfig for a specific cluster.
  Used by tests to configure specific xDS resources.
  """
  def set_config(cluster_id, %ClusterConfig{} = config) do
    :ets.insert(@config_table, {cluster_id, config})
    :ok
  end

  @doc """
  Clears all stored configurations.
  """
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    if :ets.whereis(@config_table) != :undefined do
      :ets.delete_all_objects(@config_table)
    end

    :ok
  end

  @doc """
  Inserts an API config entry and triggers a load event.
  """
  def insert_api(cluster, api_id, config \\ %{}) do
    :ets.insert(
      @table,
      {{cluster, api_id},
       %ApiConfig{
         api_id: api_id,
         cluster: cluster,
         hash: :crypto.strong_rand_bytes(10),
         config: config
       }}
    )

    :ok
  end

  @impl true
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

  @impl true
  def generate_resources(_tid, cluster_id, _changes) do
    # Check if there's a custom config set for this cluster
    case :ets.lookup(@config_table, cluster_id) do
      [{^cluster_id, config}] ->
        config

      [] ->
        # Generate a minimal valid configuration
        default_config(cluster_id)
    end
  end

  @doc """
  Generates a minimal valid ClusterConfig for testing.
  """
  def default_config(cluster_id) do
    %ClusterConfig{
      listeners: [
        %{
          "name" => "test-listener-#{cluster_id}",
          "address" => %{
            "socket_address" => %{
              "address" => "0.0.0.0",
              "port_value" => 10000
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
                      "name" => "test-route",
                      "virtual_hosts" => [
                        %{
                          "name" => "test-vhost",
                          "domains" => ["*"],
                          "routes" => [
                            %{
                              "match" => %{"prefix" => "/"},
                              "direct_response" => %{
                                "status" => 200,
                                "body" => %{
                                  "inline_string" => "OK"
                                }
                              }
                            }
                          ]
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
      clusters: [
        %{
          "name" => "test-cluster-#{cluster_id}",
          "connect_timeout" => "5s",
          "type" => "STATIC",
          "lb_policy" => "ROUND_ROBIN",
          "load_assignment" => %{
            "cluster_name" => "test-cluster-#{cluster_id}",
            "endpoints" => [
              %{
                "lb_endpoints" => [
                  %{
                    "endpoint" => %{
                      "address" => %{
                        "socket_address" => %{
                          "address" => "127.0.0.1",
                          "port_value" => 8080
                        }
                      }
                    }
                  }
                ]
              }
            ]
          }
        }
      ],
      route_configurations: [],
      scoped_route_configurations: [],
      secrets: []
    }
  end

  @doc """
  Creates a ClusterConfig with custom listener port and cluster name.
  Useful for testing configuration changes.
  """
  def make_config(opts \\ []) do
    listener_port = Keyword.get(opts, :listener_port, 10000)
    listener_name = Keyword.get(opts, :listener_name, "test-listener")
    cluster_name = Keyword.get(opts, :cluster_name, "test-cluster")
    backend_port = Keyword.get(opts, :backend_port, 8080)

    %ClusterConfig{
      listeners: [
        %{
          "name" => listener_name,
          "address" => %{
            "socket_address" => %{
              "address" => "0.0.0.0",
              "port_value" => listener_port
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
                      "name" => "test-route",
                      "virtual_hosts" => [
                        %{
                          "name" => "test-vhost",
                          "domains" => ["*"],
                          "routes" => [
                            %{
                              "match" => %{"prefix" => "/"},
                              "route" => %{
                                "cluster" => cluster_name
                              }
                            }
                          ]
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
      clusters: [
        %{
          "name" => cluster_name,
          "connect_timeout" => "5s",
          "type" => "STATIC",
          "lb_policy" => "ROUND_ROBIN",
          "load_assignment" => %{
            "cluster_name" => cluster_name,
            "endpoints" => [
              %{
                "lb_endpoints" => [
                  %{
                    "endpoint" => %{
                      "address" => %{
                        "socket_address" => %{
                          "address" => "127.0.0.1",
                          "port_value" => backend_port
                        }
                      }
                    }
                  }
                ]
              }
            ]
          }
        }
      ],
      route_configurations: [],
      scoped_route_configurations: [],
      secrets: []
    }
  end
end
