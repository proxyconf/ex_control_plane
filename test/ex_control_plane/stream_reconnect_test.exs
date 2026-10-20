defmodule ExControlPlane.StreamReconnectTest do
  use ExUnit.Case, async: false

  alias ExControlPlane.Stream

  @moduletag capture_log: true

  @cluster_type "type.googleapis.com/envoy.config.cluster.v3.Cluster"
  @resources_candidates_table :config_cache_tbl_resources_candidates

  # Minimal fakes so push_resources/1 can call GRPC.Server.Stream.send_reply/3
  # and we can observe what was put on the wire.
  defmodule FakeCodec do
    def encode(msg), do: msg
  end

  defmodule FakeAdapter do
    def send_reply(%{pid: pid}, data, _opts) do
      Agent.update(pid, fn sent -> sent ++ [data] end)
      :ok
    end
  end

  defmodule MockGRPCStream do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> [] end)
  end

  setup do
    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)
    {:ok, sup} = DynamicSupervisor.start_link(name: ExControlPlane.DynamicTestSupervisor)

    on_exit(fn ->
      Process.exit(sup, :kill)

      Enum.reverse(apps)
      |> Enum.each(fn app ->
        Application.stop(app)
        Application.unload(app)
      end)
    end)

    :ok
  end

  defp fake_stream do
    {:ok, pid} =
      DynamicSupervisor.start_child(ExControlPlane.DynamicTestSupervisor, {MockGRPCStream, []})

    {%{codec: FakeCodec, adapter: FakeAdapter, access_mode: :normal, payload: %{pid: pid}}, pid}
  end

  defp sent(pid), do: Agent.get(pid, & &1)

  defp put_resources(cluster, type_url, resources) do
    :ets.insert(@resources_candidates_table, {{cluster, type_url}, resources})
  end

  defp cluster_resources(names) do
    Enum.map(names, fn name ->
      %{"name" => name, "connect_timeout" => "5s", "type" => "STATIC"}
    end)
  end

  # Initial request of a (re)connected stream: empty nonce, version_info carrying
  # whatever the node last applied.
  defp initial_request(version_info), do: %{version_info: version_info, nonce: "", error: nil}
  defp ack(version_info, nonce), do: %{version_info: version_info, nonce: nonce, error: nil}

  defp nack(version_info, nonce),
    do: %{version_info: version_info, nonce: nonce, error: %Google.Rpc.Status{code: 3}}

  defp nonce_of(%Envoy.Service.Discovery.V3.DiscoveryResponse{nonce: nonce}), do: nonce

  # `push_resource_changes/3` replies as soon as the stream has marked itself out
  # of sync; the write to the GRPC stream happens in a continue afterwards. A
  # synchronous call to each stream lands after that continue, so this is what
  # makes "was it sent?" assertions deterministic.
  defp push(cluster, type_url, resources) do
    Stream.push_resource_changes(
      cluster,
      type_url,
      ExControlPlane.ConfigCache.checksum(resources)
    )

    Registry.select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :_}, :"$2", :_}, [{:==, :"$1", cluster}], [:"$2"]}
    ])
    |> Enum.each(&:sys.get_state/1)

    :ok
  end

  defp stream_state(grpc_stream, cluster, type_url) do
    [{pid, _}] = Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, type_url})
    {pid, :sys.get_state(pid)}
  end

  defp in_sync_flag(grpc_stream, cluster, type_url) do
    [{_pid, status}] =
      Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, type_url})

    status.in_sync
  end

  describe "reconnecting Envoy" do
    test "a second pre-reconnect request on the same stream does not kill the stream" do
      cluster = "reconnect-cluster"
      put_resources(cluster, @cluster_type, cluster_resources(["c1"]))

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      # Envoy reconnects and reports the version handed out by the *previous*
      # control plane instance.
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("7"))

      {pid, _state} = stream_state(grpc_stream, cluster, @cluster_type)
      assert [_response] = sent(agent)

      # Envoy re-sends the request (e.g. its resource subscription changed) while
      # still reporting version 7 - it has not applied our response yet.
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("7"))

      assert Process.alive?(pid), "stream GenServer must survive a pre-reconnect version"
      assert [_, _] = sent(agent)
    end

    test "full state of the world is pushed even though the node reports a version" do
      cluster = "sotw-cluster"
      put_resources(cluster, @cluster_type, cluster_resources(["c1", "c2"]))

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("41"))

      assert [%Envoy.Service.Discovery.V3.DiscoveryResponse{} = response] = sent(agent)
      assert response.version_info == "1"
      assert length(response.resources) == 2
      refute in_sync_flag(grpc_stream, cluster, @cluster_type)
    end

    test "ACK is matched on the nonce, not on the version" do
      cluster = "ack-cluster"
      put_resources(cluster, @cluster_type, cluster_resources(["c1"]))

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("7"))
      [response] = sent(agent)

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, ack("1", nonce_of(response)))

      assert in_sync_flag(grpc_stream, cluster, @cluster_type)
      assert Stream.in_sync(cluster)
    end

    test "NACK on the current nonce keeps the stream out of sync" do
      cluster = "nack-cluster"
      put_resources(cluster, @cluster_type, cluster_resources(["c1"]))

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request(""))
      [response] = sent(agent)

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, nack("", nonce_of(response)))

      refute in_sync_flag(grpc_stream, cluster, @cluster_type)
      refute Stream.in_sync(cluster)
    end

    test "stale ACK of a superseded response does not mark the stream in sync" do
      cluster = "stale-cluster"
      put_resources(cluster, @cluster_type, cluster_resources(["c1"]))

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request(""))
      [first] = sent(agent)

      # a new config supersedes the in-flight response
      updated = cluster_resources(["c1", "c2"])
      put_resources(cluster, @cluster_type, updated)
      push(cluster, @cluster_type, updated)

      assert [_first, second] = sent(agent)
      refute nonce_of(first) == nonce_of(second)

      # late ACK for the first response
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, ack("1", nonce_of(first)))
      refute in_sync_flag(grpc_stream, cluster, @cluster_type)

      # ACK for the current response
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, ack("2", nonce_of(second)))
      assert in_sync_flag(grpc_stream, cluster, @cluster_type)
    end

    test "unchanged config after a reconnect does not trigger a redundant push" do
      cluster = "no-churn-cluster"
      resources = cluster_resources(["c1"])
      put_resources(cluster, @cluster_type, resources)

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("7"))
      assert [_] = sent(agent)

      # ConfigCache regenerates an identical config (e.g. an unrelated cluster changed)
      push(cluster, @cluster_type, resources)

      assert [_] = sent(agent), "identical resources must not bump the version"
    end

    test "no resources yet: initial request is not answered with an empty response" do
      cluster = "empty-cluster"

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request("7"))

      assert [] == sent(agent)
      {_pid, state} = stream_state(grpc_stream, cluster, @cluster_type)
      assert state.version == 0

      # once resources arrive they are pushed
      resources = cluster_resources(["c1"])
      put_resources(cluster, @cluster_type, resources)
      push(cluster, @cluster_type, resources)

      assert [%Envoy.Service.Discovery.V3.DiscoveryResponse{version_info: "1"}] = sent(agent)
    end
  end
end
