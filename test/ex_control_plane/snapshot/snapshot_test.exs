defmodule ExControlPlane.Snapshot.SnapshotTest do
  alias ExControlPlane.Snapshot.Snapshot
  alias ExControlPlane.Snapshot.SnapshotTest.{MemoryBackend, CrashBackendRead, CrashBackendWrite}
  use ExUnit.Case

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    on_exit(fn ->
      :ok = Application.stop(:telemetry)
    end)
  end

  setup %{test: test} do
    on_exit(fn ->
      :telemetry.detach(test)
    end)
  end

  test "data is only written when it has changed" do
    MemoryBackend.start_link(nil)

    {:ok, _snapshot} = Snapshot.start_link(snapshot_backend_mod: MemoryBackend)

    assert 0 = MemoryBackend.wc()
    data = "value 1"
    :ok = Snapshot.put(data)
    :ok = Snapshot.force_persist()
    assert 1 = MemoryBackend.wc()

    :ok = Snapshot.put(data)
    :ok = Snapshot.force_persist()
    assert 1 = MemoryBackend.wc()

    data = "value 2"
    :ok = Snapshot.put(data)
    :ok = Snapshot.force_persist()

    assert 2 = MemoryBackend.wc()
  end

  @tag capture_log: true
  test "metrics are emitted", %{test: name} do
    self = self()

    handler_id = name

    :telemetry.attach_many(
      handler_id,
      [
        [:ex_control_plane, :snapshot, :write, :start],
        [:ex_control_plane, :snapshot, :write, :stop],
        [:ex_control_plane, :snapshot, :read, :start],
        [:ex_control_plane, :snapshot, :read, :stop]
      ],
      fn name, value, metadata, _ ->
        send(self, {:telemetry_event, name, value, metadata})
      end,
      nil
    )

    {:ok, _} = MemoryBackend.start_link(nil)

    {:ok, _snapshot} = Snapshot.start_link(snapshot_backend_mod: MemoryBackend)
    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :read, :start], _, _}
    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :read, :stop], _, _}

    refute_receive _

    data = "some_data"
    :ok = Snapshot.put(data)
    :ok = Snapshot.force_persist()

    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :write, :start], _, _}
    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :write, :stop], _, _}

    refute_receive _
  end

  @tag capture_log: true
  test "crash metrics are emitted", %{test: name} do
    self = self()

    handler_id = name

    :telemetry.attach_many(
      handler_id,
      [
        [:ex_control_plane, :snapshot, :write, :exception],
        [:ex_control_plane, :snapshot, :read, :exception]
      ],
      fn name, value, metadata, _ ->
        send(self, {:telemetry_event, name, value, metadata})
      end,
      nil
    )

    {:ok, pid} = Snapshot.start_link(snapshot_backend_mod: CrashBackendRead)

    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :read, :exception], _, _}

    refute_receive _
    :ok = GenServer.stop(pid)
    {:ok, pid} = Snapshot.start_link(snapshot_backend_mod: CrashBackendWrite)

    :ok = Snapshot.put("data")
    :ok = Snapshot.force_persist()

    assert_receive {:telemetry_event, [:ex_control_plane, :snapshot, :write, :exception], _, _}

    refute_receive _
    :ok = GenServer.stop(pid)
  end

  defmodule CrashBackendRead do
    @behaviour ExControlPlane.Snapshot.Backend

    @impl true
    def start_link(_args), do: {:ok, nil}

    @impl true
    def read(), do: throw(:crash_read)

    @impl true
    def write(_), do: :ok
  end

  defmodule CrashBackendWrite do
    @behaviour ExControlPlane.Snapshot.Backend

    @impl true
    def start_link(_args), do: {:ok, nil}

    @impl true
    def read(), do: {:ok, ""}

    @impl true
    def write(_), do: throw(:crash_write)
  end

  defmodule MemoryBackend do
    @behaviour ExControlPlane.Snapshot.Backend
    use GenServer

    @impl true
    def start_link(args) do
      GenServer.start_link(__MODULE__, args, name: __MODULE__)
    end

    @impl true
    def init(_args) do
      {:ok, %{data: "", wc: 0}}
    end

    @impl true
    def write(data) do
      GenServer.call(__MODULE__, {:write, data})
    end

    @impl true
    def read do
      GenServer.call(__MODULE__, :read)
    end

    def wc() do
      GenServer.call(__MODULE__, :wc)
    end

    @impl true
    def handle_call(
          {:write, data},
          _from,
          %{wc: old_wc} = state
        ) do
      {:reply, :ok, %{state | data: data, wc: old_wc + 1}}
    end

    @impl true
    def handle_call(:read, _from, %{data: data} = state) do
      {:reply, {:ok, data}, state}
    end

    def handle_call(:wc, _from, %{wc: wc} = state) do
      {:reply, wc, state}
    end
  end
end
