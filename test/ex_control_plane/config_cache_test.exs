defmodule ExControlPlane.ConfigCacheTest do
  use ExUnit.Case, async: false
  alias ExControlPlane.ConfigCache

  @moduletag capture_log: true
  setup %{test: test} do
    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)

    on_exit(fn ->
      :telemetry.detach(test)

      Enum.reverse(apps)
      |> Enum.each(fn app ->
        :ok = Application.stop(app)
        :ok = Application.unload(app)
      end)
    end)
  end

  test "metrics", %{test: name} do
    self = self()

    handler_id = name

    :telemetry.attach_many(
      handler_id,
      [
        [:ex_control_plane, :adapter, :generate, :start],
        [:ex_control_plane, :adapter, :generate, :stop]
      ],
      fn name, value, metadata, _ ->
        send(self, {:telemetry_event, name, value, metadata})
      end,
      nil
    )

    ConfigCache.load_events("test", [])

    assert_receive {:telemetry_event, [:ex_control_plane, :adapter, :generate, :start], _, _}
    assert_receive {:telemetry_event, [:ex_control_plane, :adapter, :generate, :stop], _, _}

    refute_receive _
  end

  test "metrics exeptions", %{test: name} do
    :ok = Application.stop(:ex_control_plane)
    Application.put_env(:ex_control_plane, :adapter_mod, __MODULE__.CrashAdapterModMock)
    :ok = Application.start(:ex_control_plane)

    self = self()

    handler_id = name

    :telemetry.attach_many(
      handler_id,
      [
        [:ex_control_plane, :adapter, :generate, :start],
        [:ex_control_plane, :adapter, :generate, :stop],
        [:ex_control_plane, :adapter, :generate, :exception]
      ],
      fn name, value, metadata, _ ->
        send(self, {:telemetry_event, name, value, metadata})
      end,
      nil
    )

    ConfigCache.load_events("test", [])

    assert_receive {:telemetry_event, [:ex_control_plane, :adapter, :generate, :start], _, _}
    assert_receive {:telemetry_event, [:ex_control_plane, :adapter, :generate, :exception], _, _}

    refute_receive _
  end

  defmodule CrashAdapterModMock do
    def init, do: %{}

    def map_reduce(_, _, _), do: {[], []}

    def generate(_state, _cluster, _changed_apis),
      do: raise(%ArgumentError{message: "argumenterror"})
  end
end
