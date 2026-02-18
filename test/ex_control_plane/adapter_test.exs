defmodule ExControlPlane.AdapterTest do
  use ExUnit.Case, async: true

  alias ExControlPlane.Adapter
  alias ExControlPlane.Adapter.{ApiConfig, ClusterConfig}

  describe "ApiConfig struct" do
    test "has expected fields" do
      config = %ApiConfig{}

      assert Map.has_key?(config, :api_id)
      assert Map.has_key?(config, :cluster)
      assert Map.has_key?(config, :hash)
      assert Map.has_key?(config, :config)
    end

    test "fields default to nil" do
      config = %ApiConfig{}

      assert config.api_id == nil
      assert config.cluster == nil
      assert config.hash == nil
      assert config.config == nil
    end

    test "can be created with values" do
      config = %ApiConfig{
        api_id: "my-api",
        cluster: "production",
        hash: <<1, 2, 3, 4>>,
        config: %{"key" => "value"}
      }

      assert config.api_id == "my-api"
      assert config.cluster == "production"
      assert config.hash == <<1, 2, 3, 4>>
      assert config.config == %{"key" => "value"}
    end

    test "can be pattern matched" do
      config = %ApiConfig{api_id: "test", cluster: "dev"}

      assert %ApiConfig{api_id: "test"} = config
      assert %ApiConfig{cluster: cluster} = config
      assert cluster == "dev"
    end
  end

  describe "ClusterConfig struct" do
    test "has expected fields" do
      config = %ClusterConfig{}

      assert Map.has_key?(config, :secrets)
      assert Map.has_key?(config, :listeners)
      assert Map.has_key?(config, :clusters)
      assert Map.has_key?(config, :route_configurations)
      assert Map.has_key?(config, :scoped_route_configurations)
    end

    test "fields default to empty lists" do
      config = %ClusterConfig{}

      assert config.secrets == []
      assert config.listeners == []
      assert config.clusters == []
      assert config.route_configurations == []
      assert config.scoped_route_configurations == []
    end

    test "can be created with values" do
      config = %ClusterConfig{
        secrets: [%{"name" => "secret1"}],
        listeners: [%{"name" => "listener1"}],
        clusters: [%{"name" => "cluster1"}],
        route_configurations: [%{"name" => "route1"}],
        scoped_route_configurations: [%{"name" => "scoped1"}]
      }

      assert length(config.secrets) == 1
      assert length(config.listeners) == 1
      assert length(config.clusters) == 1
      assert length(config.route_configurations) == 1
      assert length(config.scoped_route_configurations) == 1
    end

    test "represents complete Envoy xDS configuration" do
      # This test documents the expected structure for xDS resources
      config = %ClusterConfig{
        listeners: [
          %{
            "name" => "http_listener",
            "address" => %{
              "socket_address" => %{
                "address" => "0.0.0.0",
                "port_value" => 8080
              }
            }
          }
        ],
        clusters: [
          %{
            "name" => "backend_cluster",
            "type" => "STRICT_DNS",
            "lb_policy" => "ROUND_ROBIN"
          }
        ]
      }

      [listener] = config.listeners
      assert listener["name"] == "http_listener"

      [cluster] = config.clusters
      assert cluster["name"] == "backend_cluster"
    end
  end

  describe "Adapter behaviour" do
    test "defines required callbacks" do
      # Get the behaviour callbacks
      callbacks = Adapter.behaviour_info(:callbacks)

      # Check init/0 callback
      assert {:init, 0} in callbacks

      # Check map_reduce/3 callback
      assert {:map_reduce, 3} in callbacks

      # Check generate_resources/3 callback
      assert {:generate_resources, 3} in callbacks
    end
  end
end
