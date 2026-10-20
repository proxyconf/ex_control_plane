defmodule ExControlPlane.StreamTest do
  use ExUnit.Case, async: false

  setup do
    Application.ensure_all_started(:ex_control_plane)

    # start a supervisor to dynamically start mock GRPC connections inside tests
    {:ok, pid} = DynamicSupervisor.start_link(name: ExControlPlane.DynamicTestSupervisor)

    on_exit(fn ->
      Application.stop(:ex_control_plane)
      Application.unload(:ex_control_plane)
      Process.exit(pid, :kill)
    end)
  end

  test "grpc stream is terminated" do
    # start a mock GRPC stream
    {:ok, grpc_stream_pid} =
      DynamicSupervisor.start_child(ExControlPlane.DynamicTestSupervisor, {MockGRPCStream, []})

    grpc_stream = %{payload: %{pid: grpc_stream_pid}}
    node_info = %{cluster: "cluster", node_id: "id"}
    type_url = "type.googleapis.com/envoy.config.route.v3.ScopedRouteConfiguration"

    {:ok, stream_pid} = ExControlPlane.Stream.ensure_registred(grpc_stream, node_info, type_url)

    key = {grpc_stream, node_info.cluster, type_url}
    assert [{^stream_pid, _}] = Registry.lookup(ExControlPlane.StreamRegistry, key)
    assert stream_pid in stream_children()

    # kill grpc stream
    true = Process.exit(grpc_stream_pid, :kill)

    # Killing the GRPC Stream should stop the responsible Stream GenServer
    assert wait(fn -> not Process.alive?(stream_pid) end, 1000)

    # and be removed from dynamic supervisor
    assert wait(fn -> stream_pid not in stream_children() end, 1000)

    # and not longer register in StreamRegistry
    assert wait(fn -> Registry.lookup(ExControlPlane.StreamRegistry, key) == [] end, 1000)
  end

  test "two concurrent GRPC Streams and terminating one of them" do
    # start two mock GRPC Streams
    {:ok, grpc_stream_pid} =
      DynamicSupervisor.start_child(ExControlPlane.DynamicTestSupervisor, {MockGRPCStream, []})

    {:ok, grpc_stream_pid2} =
      DynamicSupervisor.start_child(ExControlPlane.DynamicTestSupervisor, {MockGRPCStream, []})

    grpc_stream = %{payload: %{pid: grpc_stream_pid}}
    grpc_stream2 = %{payload: %{pid: grpc_stream_pid2}}
    node_info = %{cluster: "cluster", node_id: "id"}
    type_url = "type.googleapis.com/envoy.config.route.v3.ScopedRouteConfiguration"

    {:ok, stream_pid} =
      ExControlPlane.Stream.ensure_registred(grpc_stream, node_info, type_url)

    {:ok, stream_pid2} =
      ExControlPlane.Stream.ensure_registred(grpc_stream2, node_info, type_url)

    # two Streams should be registered and running
    stream_pid_list = [stream_pid, stream_pid2] |> Enum.sort()

    children = stream_children()
    assert stream_pid in children
    assert stream_pid2 in children

    assert stream_pid_list ==
             Registry.select(ExControlPlane.StreamRegistry, [
               {{{:_, :"$1", :"$2"}, :"$3", :_},
                [{:==, :"$1", node_info.cluster}, {:==, :"$2", type_url}], [:"$3"]}
             ])
             |> Enum.sort()

    # kill ONE GRPC Stream
    true = Process.exit(grpc_stream_pid, :kill)

    # Killing the GRPC Stream should stop the responsible Stream GenServer
    assert wait(fn -> not Process.alive?(stream_pid) end, 1000)

    # and deregister/be removed from dynamic supervisor
    # the second GRPC Stream should still be there
    assert wait(fn -> stream_pid not in stream_children() end, 1000)
    assert Process.alive?(stream_pid2)
    assert stream_pid2 in stream_children()

    # registry has been updated and contains only the new PID
    assert [^stream_pid2] =
             Registry.select(ExControlPlane.StreamRegistry, [
               {{{:_, :"$1", :"$2"}, :"$3", :_},
                [{:==, :"$1", node_info.cluster}, {:==, :"$2", type_url}], [:"$3"]}
             ])
  end

  # Scoped to the streams a test owns: the supervisor and the registry are global
  # and anything that connects to the control plane shows up there too.
  defp stream_children do
    DynamicSupervisor.which_children(ExControlPlane.StreamSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  defp wait(_f, until) when until <= 0, do: false

  defp wait(f, until) do
    if f.() do
      :ok
    else
      Process.sleep(100)
      wait(f, until - 100)
    end
  end
end

defmodule MockGRPCStream do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end)
  end
end
