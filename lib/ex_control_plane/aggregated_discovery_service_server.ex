defmodule ExControlPlane.AggregatedDiscoveryServiceServer do
  @moduledoc false
  require Logger
  use GRPC.Server, service: Envoy.Service.Discovery.V3.AggregatedDiscoveryService.Service

  alias Envoy.Service.Discovery.V3.DiscoveryRequest
  alias Envoy.Config.Core.V3.Node

  # The xDS protocol only requires the node identifier on the first request of a
  # stream, subsequent requests may omit it. The node is therefore carried
  # through the request stream instead of being re-read from every request.
  def stream_aggregated_resources(request, stream) do
    Enum.reduce(request, nil, fn r, node_info ->
      handle_discovery_request(r, stream, node_info)
    end)

    :ok
  end

  defp handle_discovery_request(
         %DiscoveryRequest{
           version_info: version,
           response_nonce: nonce,
           error_detail: error,
           resource_names: _,
           type_url: type_url
         } = req,
         stream,
         previous_node_info
       ) do
    case node_info(req, previous_node_info) do
      {:ok, node_info} ->
        if not is_nil(error) do
          Logger.error("ADS discovery request error #{inspect(error)}")
        end

        # `version_info` is opaque to the node and survives reconnects, it is
        # forwarded for logging only. The `response_nonce` decides whether this
        # is an initial request, an ACK, or a NACK.
        ExControlPlane.Stream.event(stream, node_info, type_url, %{
          version_info: version,
          nonce: nonce,
          error: error
        })

        node_info

      :error ->
        # Nothing identifies the node, so the request cannot be routed to a
        # cluster. Drop it instead of tearing down the stream.
        Logger.error(
          "ADS discovery request for #{inspect(type_url)} without node identification, ignoring"
        )

        previous_node_info
    end
  end

  defp handle_discovery_request(req, _stream, previous_node_info) do
    Logger.error("Unexpected ADS request #{inspect(req)}, ignoring")
    previous_node_info
  end

  defp node_info(%DiscoveryRequest{node: %Node{id: node_id, cluster: cluster}}, _previous) do
    {:ok, %{cluster: cluster, node_id: node_id}}
  end

  defp node_info(%DiscoveryRequest{}, nil), do: :error
  defp node_info(%DiscoveryRequest{}, previous), do: {:ok, previous}
end
