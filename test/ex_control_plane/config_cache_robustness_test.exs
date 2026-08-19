defmodule ExControlPlane.ConfigCacheRobustnessTest do
  use ExUnit.Case, async: false

  alias ExControlPlane.ConfigCache

  @moduletag capture_log: true

  defmodule RaisingAdapter do
    def init, do: %{}
    def map_reduce(_, _, acc), do: {[], acc}
    def generate_resources(_state, _cluster, _changes), do: raise("adapter exploded")
  end

  defmodule GarbageAdapter do
    def init, do: %{}
    def map_reduce(_, _, acc), do: {[], acc}
    def generate_resources(_state, _cluster, _changes), do: %{not: "a cluster config"}
  end

  defmodule SlowAdapter do
    def init, do: %{}
    def map_reduce(_, _, acc), do: {[], acc}

    def generate_resources(_state, _cluster, _changes) do
      %ExControlPlane.Adapter.ClusterConfig{}
    end
  end

  defp start_with_adapter(adapter) do
    Application.put_env(:ex_control_plane, :adapter_mod, adapter)
    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)

    on_exit(fn ->
      Enum.reverse(apps)
      |> Enum.each(fn app ->
        Application.stop(app)
        Application.unload(app)
      end)

      Application.delete_env(:ex_control_plane, :adapter_mod)
    end)

    :ok
  end

  test "a raising adapter is reported instead of being swallowed as success" do
    start_with_adapter(RaisingAdapter)

    assert {:error, :failed_generating_configuration} =
             ConfigCache.load_events("test", [{:updated, "api"}])
  end

  test "an adapter returning a non-ClusterConfig is reported" do
    start_with_adapter(GarbageAdapter)

    assert {:error, :invalid_cluster_config} =
             ConfigCache.load_events("test", [{:updated, "api"}])
  end

  test "a crashing adapter does not take the config cache down" do
    start_with_adapter(RaisingAdapter)

    pid = Process.whereis(ConfigCache)
    assert {:error, _} = ConfigCache.load_events("test", [{:updated, "api"}])
    assert Process.whereis(ConfigCache) == pid
    assert Process.alive?(pid)
  end

  test "the config cache stays responsive while a load_events call is waiting" do
    start_with_adapter(SlowAdapter)

    # A stream that never acknowledges keeps "stuck-cluster" out of sync, so its
    # load_events has to sit through the full sync_wait_timeout.
    register_never_acking_stream("stuck-cluster")
    assert ExControlPlane.Stream.sync_status("stuck-cluster") == :out_of_sync

    stuck = Task.async(fn -> ConfigCache.load_events("stuck-cluster", [], 3_000) end)

    # Give the stuck call time to enter its sync wait.
    Process.sleep(200)

    # A second cluster must not queue behind the first one's sync wait.
    {micros, result} =
      :timer.tc(fn -> ConfigCache.load_events("other-cluster", [], 1_000) end)

    assert result == :ok

    assert micros < 2_000_000,
           "load_events queued behind an unrelated cluster's sync wait (#{div(micros, 1000)}ms)"

    assert {:error, :no_sync_state_reached} = Task.await(stuck, 10_000)
  end

  defmodule FakeCodec do
    def encode(msg), do: msg
  end

  defmodule FakeAdapter do
    def send_reply(_payload, _data, _opts), do: :ok
  end

  # A real stream that received its resources but never sends an ACK back, which
  # is what a healthy-but-lagging node looks like.
  defp register_never_acking_stream(cluster) do
    type_url = "type.googleapis.com/envoy.config.cluster.v3.Cluster"

    :ets.insert(
      :config_cache_tbl_resources_candidates,
      {{cluster, type_url}, [%{"name" => "c1", "connect_timeout" => "5s", "type" => "STATIC"}]}
    )

    {:ok, agent} = Agent.start_link(fn -> [] end)

    grpc_stream = %{
      codec: FakeCodec,
      adapter: FakeAdapter,
      access_mode: :normal,
      payload: %{pid: agent}
    }

    :ok =
      ExControlPlane.Stream.event(
        grpc_stream,
        %{cluster: cluster, node_id: "lagging-node"},
        type_url,
        %{version_info: "", nonce: "", error: nil}
      )

    agent
  end

  test "load_events succeeds when no node is connected but says so" do
    start_with_adapter(SlowAdapter)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ConfigCache.load_events("unconnected", [], 1_000)
      end)

    assert log =~ "No node connected"
  end

  test "checksum is stable and order sensitive" do
    start_with_adapter(SlowAdapter)

    a = [%{"name" => "c1"}, %{"name" => "c2"}]

    assert ConfigCache.checksum(a) == ConfigCache.checksum([%{"name" => "c1"}, %{"name" => "c2"}])
    refute ConfigCache.checksum(a) == ConfigCache.checksum(Enum.reverse(a))
  end
end
