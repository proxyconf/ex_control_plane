defmodule ExControlPlane.SampleEtsAdapterTest do
  use ExUnit.Case, async: false

  alias ExControlPlane.SampleEtsAdapter
  alias ExControlPlane.Adapter.{ApiConfig, ClusterConfig}

  setup do
    # Clean up any existing table
    try do
      :ets.delete(SampleEtsAdapter)
    rescue
      ArgumentError -> :ok
    end

    # Initialize the adapter
    tid = SampleEtsAdapter.init()

    on_exit(fn ->
      try do
        :ets.delete(SampleEtsAdapter)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, tid: tid}
  end

  describe "init/0" do
    test "creates a named ETS table", %{tid: tid} do
      assert tid == SampleEtsAdapter
      assert :ets.info(SampleEtsAdapter) != :undefined
    end

    test "table has correct options" do
      info = :ets.info(SampleEtsAdapter)
      assert info[:named_table] == true
      assert info[:protection] == :public
    end
  end

  describe "get_api_config/3" do
    test "returns config for existing entry", %{tid: tid} do
      # Insert directly via ETS for test isolation
      config = %ApiConfig{
        api_id: "test-api",
        cluster: "test-cluster",
        hash: <<1, 2, 3>>,
        config: %{"key" => "value"}
      }

      :ets.insert(tid, {{"test-cluster", "test-api"}, config})

      assert {:ok, ^config} = SampleEtsAdapter.get_api_config(tid, "test-cluster", "test-api")
    end

    test "returns error for non-existing entry", %{tid: tid} do
      assert {:error, "not_found"} =
               SampleEtsAdapter.get_api_config(tid, "missing-cluster", "missing-api")
    end
  end

  describe "map_reduce/3" do
    test "iterates over all entries with accumulator", %{tid: tid} do
      # Insert multiple configs
      config1 = %ApiConfig{api_id: "api-1", cluster: "cluster", hash: <<1>>, config: %{}}
      config2 = %ApiConfig{api_id: "api-2", cluster: "cluster", hash: <<2>>, config: %{}}
      config3 = %ApiConfig{api_id: "api-3", cluster: "cluster", hash: <<3>>, config: %{}}

      :ets.insert(tid, {{"cluster", "api-1"}, config1})
      :ets.insert(tid, {{"cluster", "api-2"}, config2})
      :ets.insert(tid, {{"cluster", "api-3"}, config3})

      # Map function that extracts api_ids and counts
      mapper_fn = fn config, count ->
        {[config.api_id], count + 1}
      end

      {results, count} = SampleEtsAdapter.map_reduce(tid, mapper_fn, 0)

      assert count == 3
      assert length(results) == 3
      assert Enum.sort(results) == ["api-1", "api-2", "api-3"]
    end

    test "returns empty results for empty table", %{tid: tid} do
      mapper_fn = fn config, acc -> {[config.api_id], acc} end

      {results, acc} = SampleEtsAdapter.map_reduce(tid, mapper_fn, :initial)

      assert results == []
      assert acc == :initial
    end

    test "handles complex accumulator transformations", %{tid: tid} do
      config1 = %ApiConfig{
        api_id: "api-1",
        cluster: "cluster",
        hash: <<1>>,
        config: %{"size" => 10}
      }

      config2 = %ApiConfig{
        api_id: "api-2",
        cluster: "cluster",
        hash: <<2>>,
        config: %{"size" => 20}
      }

      :ets.insert(tid, {{"cluster", "api-1"}, config1})
      :ets.insert(tid, {{"cluster", "api-2"}, config2})

      mapper_fn = fn config, sizes ->
        size = config.config["size"]
        {[{config.api_id, size}], [size | sizes]}
      end

      {results, sizes} = SampleEtsAdapter.map_reduce(tid, mapper_fn, [])

      assert length(results) == 2
      assert Enum.sort(sizes) == [10, 20]
    end
  end

  describe "generate_resources/3" do
    test "returns a ClusterConfig struct", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      assert %ClusterConfig{} = result
    end

    test "contains listeners configuration", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      assert [listener | _] = result.listeners
      assert listener["address"]["socket_address"]["address"] == "0.0.0.0"
      assert listener["address"]["socket_address"]["port_value"] == 8080
    end

    test "contains filter chains with http_connection_manager", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      [listener] = result.listeners
      [filter_chain] = listener["filter_chains"]
      [filter] = filter_chain["filters"]

      assert filter["name"] == "envoy.filters.network.http_connection_manager"
      assert filter["typed_config"]["stat_prefix"] == "ingress_http"
    end

    test "contains route configuration with virtual hosts", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      [listener] = result.listeners
      [filter_chain] = listener["filter_chains"]
      [filter] = filter_chain["filters"]

      route_config = filter["typed_config"]["route_config"]
      assert route_config["name"] == "httpbin_route"

      [virtual_host] = route_config["virtual_hosts"]
      assert virtual_host["name"] == "httpbin"
      assert virtual_host["domains"] == ["*"]
      assert length(virtual_host["routes"]) > 0
    end

    test "contains clusters from OpenAPI transformation", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      assert length(result.clusters) > 0

      [cluster | _] = result.clusters
      assert is_binary(cluster["name"])
      assert cluster["connect_timeout"] == "5s"
      assert cluster["type"] == "STRICT_DNS"
      assert cluster["lb_policy"] == "ROUND_ROBIN"
    end

    test "clusters have TLS configuration for HTTPS", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      [cluster | _] = result.clusters

      transport_socket = cluster["transport_socket"]
      assert transport_socket["name"] == "envoy.transport_sockets.tls"
      assert transport_socket["typed_config"]["@type"] =~ "UpstreamTlsContext"
    end

    test "clusters have load assignment endpoints", %{tid: tid} do
      result = SampleEtsAdapter.generate_resources(tid, "cluster", [])

      [cluster | _] = result.clusters

      load_assignment = cluster["load_assignment"]
      assert load_assignment["cluster_name"] == cluster["name"]

      [endpoint_group] = load_assignment["endpoints"]
      [lb_endpoint] = endpoint_group["lb_endpoints"]
      socket_address = lb_endpoint["endpoint"]["address"]["socket_address"]

      assert is_binary(socket_address["address"])
      assert is_integer(socket_address["port_value"])
    end
  end
end
