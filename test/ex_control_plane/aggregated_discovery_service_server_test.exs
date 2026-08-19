defmodule ExControlPlane.AggregatedDiscoveryServiceServerTest do
  use ExUnit.Case, async: false

  alias ExControlPlane.AggregatedDiscoveryServiceServer
  alias Envoy.Service.Discovery.V3.DiscoveryRequest
  alias Envoy.Config.Core.V3.Node
  alias Google.Rpc.Status

  import ExUnit.CaptureLog

  @moduletag capture_log: true

  @cluster_type "type.googleapis.com/envoy.config.cluster.v3.Cluster"
  @listener_type "type.googleapis.com/envoy.config.listener.v3.Listener"

  describe "stream_aggregated_resources/2" do
    setup do
      {:ok, apps} = Application.ensure_all_started(:ex_control_plane)

      on_exit(fn ->
        Enum.reverse(apps)
        |> Enum.each(fn app ->
          Application.stop(app)
          Application.unload(app)
        end)
      end)

      :ok
    end

    defp request(opts) do
      %DiscoveryRequest{
        version_info: Keyword.get(opts, :version_info, ""),
        response_nonce: Keyword.get(opts, :nonce, ""),
        node: Keyword.get(opts, :node, %Node{id: "test-node", cluster: "test-cluster"}),
        type_url: Keyword.get(opts, :type_url, @cluster_type),
        resource_names: [],
        error_detail: Keyword.get(opts, :error, nil)
      }
    end

    # A broken stream must degrade to an error, never take the handler down: an
    # exception here would tear down the node's whole ADS session.
    defp mock_stream do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
      agent
    end

    test "an unusable stream does not raise out of the handler" do
      stream = mock_stream()

      assert :ok =
               AggregatedDiscoveryServiceServer.stream_aggregated_resources(
                 [request(version_info: "42")],
                 stream
               )
    end

    test "handles discovery request with empty version (first timer)" do
      stream = mock_stream()

      assert :ok =
               AggregatedDiscoveryServiceServer.stream_aggregated_resources(
                 [request(version_info: "", type_url: @listener_type)],
                 stream
               )
    end

    test "accepts an opaque non-numeric version" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          AggregatedDiscoveryServiceServer.stream_aggregated_resources(
            [request(version_info: "invalid-version")],
            stream
          )
        end)

      # version_info is opaque to the node, the server must not try to parse it
      refute log =~ "Invalid ADS discovery request version"
    end

    test "handles version with trailing characters" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          AggregatedDiscoveryServiceServer.stream_aggregated_resources(
            [request(version_info: "42abc")],
            stream
          )
        end)

      refute log =~ "Invalid ADS discovery request version"
    end

    test "logs error when error_detail is present" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          AggregatedDiscoveryServiceServer.stream_aggregated_resources(
            [request(version_info: "10", nonce: "n1", error: %Status{code: 2, message: "nope"})],
            stream
          )
        end)

      assert log =~ "ADS discovery request error"
    end

    test "node identity carries over to requests that omit it" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          AggregatedDiscoveryServiceServer.stream_aggregated_resources(
            [
              request(type_url: @cluster_type),
              # xDS only requires the node on the first request of a stream
              request(type_url: @listener_type, node: nil)
            ],
            stream
          )
        end)

      refute log =~ "without node identification"
      assert log =~ @listener_type
    end

    test "a request without any node identity is dropped, not fatal" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          assert :ok =
                   AggregatedDiscoveryServiceServer.stream_aggregated_resources(
                     [request(node: nil)],
                     stream
                   )
        end)

      assert log =~ "without node identification"
    end

    test "one broken request does not stop the rest of the stream" do
      stream = mock_stream()

      log =
        capture_log(fn ->
          assert :ok =
                   AggregatedDiscoveryServiceServer.stream_aggregated_resources(
                     [
                       request(node: nil),
                       request(type_url: @listener_type)
                     ],
                     stream
                   )
        end)

      assert log =~ "without node identification"
      assert log =~ @listener_type
    end
  end
end
