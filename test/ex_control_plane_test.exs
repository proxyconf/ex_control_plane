defmodule ExControlPlaneTest do
  use ExUnit.Case
  doctest ExControlPlane

  setup_all do
    {:ok, _mock} = ExControlPlaneTest.AwsMock.start_link(nil)
    :ok
  end

  test "no snapshot_configured" do
    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)

    Enum.reverse(apps)
    |> Enum.each(fn app ->
      :ok = Application.stop(app)
      :ok = Application.unload(app)
    end)
  end

  test "load from snapshot on s3 (mocked)" do
    Application.put_env(:ex_control_plane, :snapshot_backend_mod, ExControlPlane.Snapshot.S3)
    Application.put_env(:ex_control_plane, :snapshot_backend_args, bucket: "bucket", key: "key")

    Application.put_env(:ex_control_plane, :aws_config_overrides, %{
      http_client: ExControlPlaneTest.AwsMock,
      access_key_id: "ignore",
      secret_access_key: "ignore",
      json_codec: JSON
    })

    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)
    assert 0 == map_size(ExControlPlaneTest.AwsMock.dump())
    assert :ok = ExControlPlane.ConfigCache.load_events("test", [])
    :ok = ExControlPlane.Snapshot.Snapshot.force_persist()
    assert 1 == map_size(ExControlPlaneTest.AwsMock.dump())

    :ok = Application.stop(:ex_control_plane)
    # ensure configs are loaded from snapshot and not via the adapter. Use a crashing adapter.
    Application.put_env(:ex_control_plane, :adapter_mod, ExControlPlaneTest.CrashAdapterModMock)
    :ok = Application.start(:ex_control_plane)

    cluster = "test"
    type_url = "type.googleapis.com/envoy.config.cluster.v3.Cluster"

    f = fn ->
      case ExControlPlane.ConfigCache.get_resources(cluster, type_url) do
        [] -> false
        res -> res
      end
    end

    assert [_ | _] = wait_until(f, 1000)

    Enum.reverse(apps)
    |> Enum.each(fn app ->
      :ok = Application.stop(app)
      :ok = Application.unload(app)
    end)
  end

  def wait_until(f, until) do
    case f.() do
      false ->
        Process.sleep(100)
        wait_until(f, until - 100)

      res ->
        res
    end
  end

  defmodule CrashAdapterModMock do
    def init, do: %{}

    def map_reduce(_, _, _), do: {[], []}

    def generate(_state, _cluster, _changed_apis),
      do: raise(%ArgumentError{message: "argumenterror"})
  end

  defmodule AwsMock do
    use GenServer

    def start_link(_) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_) do
      {:ok, %{}}
    end

    def request(:put, "https://s3.amazonaws.com/" <> _ = url, body, headers, []) do
      key = {url, get_host(headers)}
      GenServer.call(__MODULE__, {:put, key, body})
    end

    def request(:get, "https://s3.amazonaws.com/" <> _ = url, _body, headers, []) do
      key = {url, get_host(headers)}
      GenServer.call(__MODULE__, {:get, key})
    end

    def dump do
      GenServer.call(__MODULE__, :dump)
    end

    defp get_host(headers) do
      headers
      |> Enum.find_value(fn {key, val} -> if key == "host", do: val end)
    end

    @impl true
    def handle_call({:put, key, body}, _from, state) do
      {:reply, {:ok, %{status_code: 200}}, Map.put(state, key, body)}
    end

    def handle_call({:get, key}, _from, state) do
      {code, body} =
        case Map.get(state, key) do
          nil -> {404, ""}
          body -> {200, body}
        end

      {:reply, {:ok, %{status_code: code, body: body}}, state}
    end

    def handle_call(:dump, _from, state) do
      {:reply, state, state}
    end
  end
end
