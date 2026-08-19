defmodule ExControlPlane.StreamRobustnessTest do
  use ExUnit.Case, async: false

  alias ExControlPlane.Stream

  @moduletag capture_log: true

  @cluster_type "type.googleapis.com/envoy.config.cluster.v3.Cluster"
  @resources_candidates_table :config_cache_tbl_resources_candidates

  defmodule FakeCodec do
    def encode(msg), do: msg
  end

  defmodule FakeAdapter do
    def send_reply(%{pid: pid}, data, _opts) do
      Agent.update(pid, fn sent -> sent ++ [data] end)
      :ok
    end
  end

  # Simulates a node whose GRPC stream has become unwritable.
  defmodule FailingAdapter do
    def send_reply(_payload, _data, _opts), do: raise("connection reset")
  end

  # Simulates a node that never drains its HTTP/2 window.
  defmodule BlockingAdapter do
    def send_reply(_payload, _data, _opts) do
      Process.sleep(:infinity)
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
      Application.delete_env(:ex_control_plane, :stream_push_timeout)

      Enum.reverse(apps)
      |> Enum.each(fn app ->
        Application.stop(app)
        Application.unload(app)
      end)
    end)

    :ok
  end

  defp fake_stream(adapter \\ FakeAdapter) do
    {:ok, pid} =
      DynamicSupervisor.start_child(ExControlPlane.DynamicTestSupervisor, {MockGRPCStream, []})

    {%{codec: FakeCodec, adapter: adapter, access_mode: :normal, payload: %{pid: pid}}, pid}
  end

  defp sent(pid), do: Agent.get(pid, & &1)

  defp resources(names) do
    Enum.map(names, fn name ->
      %{"name" => name, "connect_timeout" => "5s", "type" => "STATIC"}
    end)
  end

  defp put_resources(cluster, res),
    do: :ets.insert(@resources_candidates_table, {{cluster, @cluster_type}, res})

  defp initial_request, do: %{version_info: "", nonce: "", error: nil}

  # `push_resource_changes/3` replies as soon as the stream has marked itself out
  # of sync; the write to the GRPC stream happens in a continue afterwards. A
  # synchronous call to each stream lands after that continue, so this is what
  # makes "was it sent?" assertions deterministic.
  defp push(cluster, res) do
    Stream.push_resource_changes(
      cluster,
      @cluster_type,
      ExControlPlane.ConfigCache.checksum(res)
    )

    Registry.select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :_}, :"$2", :_}, [{:==, :"$1", cluster}], [:"$2"]}
    ])
    |> Enum.each(&:sys.get_state/1)

    :ok
  end

  describe "sync_status/1" do
    test "distinguishes no connected nodes from in sync" do
      assert Stream.sync_status("nobody-here") == :no_connected_nodes
      # in_sync/1 cannot tell the two apart, which is why sync_status/1 exists
      assert Stream.in_sync("nobody-here")
    end

    test "reports out_of_sync until the node acknowledges" do
      cluster = "sync-status-cluster"
      res = resources(["c1"])
      put_resources(cluster, res)

      {grpc_stream, agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request())
      assert Stream.sync_status(cluster) == :out_of_sync

      [response] = sent(agent)

      :ok =
        Stream.event(grpc_stream, node_info, @cluster_type, %{
          version_info: "1",
          nonce: response.nonce,
          error: nil
        })

      assert Stream.sync_status(cluster) == :in_sync
    end
  end

  describe "fault isolation of push_resource_changes/3" do
    test "a dead stream does not fail the caller" do
      cluster = "dead-stream-cluster"
      res = resources(["c1"])
      put_resources(cluster, res)

      {grpc_stream, _agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request())

      [{pid, _}] =
        Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, @cluster_type})

      Process.exit(pid, :kill)

      # The registry entry may still be visible for a moment after the kill.
      assert :ok = push(cluster, resources(["c1", "c2"]))
    end

    test "a stream whose connection broke stays out of sync instead of dying" do
      cluster = "broken-stream-cluster"
      put_resources(cluster, resources(["c1"]))

      {grpc_stream, _agent} = fake_stream(FailingAdapter)
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request())

      [{pid, _}] =
        Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, @cluster_type})

      assert Process.alive?(pid), "a failed send must not take the stream down"
      assert Stream.sync_status(cluster) == :out_of_sync

      # nothing was delivered, so neither version nor hash advanced
      state = :sys.get_state(pid)
      assert state.version == 0
      assert state.hash == nil
    end

    test "a blocked stream cannot stall the caller forever" do
      Application.put_env(:ex_control_plane, :stream_push_timeout, 200)

      cluster = "blocked-stream-cluster"
      put_resources(cluster, resources(["c1"]))

      {grpc_stream, _agent} = fake_stream(BlockingAdapter)
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      task =
        Task.async(fn ->
          Stream.event(grpc_stream, node_info, @cluster_type, initial_request())
        end)

      assert {:error, _} = Task.await(task, 5_000)
      assert Stream.sync_status(cluster) == :out_of_sync
    end

    test "a healthy stream still receives its push when a sibling is broken" do
      cluster = "mixed-cluster"
      put_resources(cluster, resources(["c1"]))

      {broken_stream, _} = fake_stream(FailingAdapter)
      {healthy_stream, healthy_agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}

      :ok = Stream.event(broken_stream, node_info, @cluster_type, initial_request())
      :ok = Stream.event(healthy_stream, node_info, @cluster_type, initial_request())

      assert [_] = sent(healthy_agent)

      updated = resources(["c1", "c2"])
      put_resources(cluster, updated)
      assert :ok = push(cluster, updated)

      assert [_, _] = sent(healthy_agent)
    end
  end

  describe "stream lifetime" do
    test "a crashing stream is not restarted behind a dead GRPC connection" do
      cluster = "no-restart-cluster"
      put_resources(cluster, resources(["c1"]))

      {grpc_stream, _agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request())

      [{pid, _}] =
        Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, @cluster_type})

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # transient children would come back and re-register for a connection that
      # the node has to re-establish anyway
      Process.sleep(100)

      assert Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, @cluster_type}) ==
               []

      assert %{active: 0} = DynamicSupervisor.count_children(ExControlPlane.StreamSupervisor)
    end

    test "an unexpected message or call does not take a stream down" do
      cluster = "noise-cluster"
      put_resources(cluster, resources(["c1"]))

      {grpc_stream, _agent} = fake_stream()
      node_info = %{cluster: cluster, node_id: "envoy-1"}
      :ok = Stream.event(grpc_stream, node_info, @cluster_type, initial_request())

      [{pid, _}] =
        Registry.lookup(ExControlPlane.StreamRegistry, {grpc_stream, cluster, @cluster_type})

      send(pid, :something_unexpected)
      assert {:error, :unhandled_request} = GenServer.call(pid, :nonsense)
      assert Process.alive?(pid)
    end
  end
end
