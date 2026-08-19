# ExControlPlane

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_control_plane` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_control_plane, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ex_control_plane>.

## Configuration

```elixir
config :ex_control_plane,
  # GRPC endpoint the dataplane connects to
  grpc_endpoint_port: 18000,
  grpc_start_server: true,

  # Module implementing the ExControlPlane.Adapter behaviour
  adapter_mod: MyApp.Adapter,

  # How long a single push to one discovery stream may take before it is given
  # up on. The stream stays out of sync and retries on the next change, rather
  # than holding up config distribution to the rest of the dataplane.
  stream_push_timeout: 10_000,

  # Upper bound on concurrently accepted discovery streams. Beyond it further
  # streams are rejected and logged instead of growing the process count
  # without end.
  max_concurrent_streams: :infinity,

  # Optional snapshot backend used to bootstrap on a cold start
  snapshot_backend_mod: ExControlPlane.Snapshot.S3,
  snapshot_backend_args: [bucket: "bucket", key: "key"],
  snapshot_persist_interval: 600_000
```

## Synchronisation state

`ExControlPlane.ConfigCache.load_events/4` pushes a configuration and waits for
the dataplane to acknowledge it:

- `:ok` - every connected node acknowledged, **or** no node is connected at all
  (logged as a warning - it is not evidence the configuration is good)
- `{:error, :no_sync_state_reached}` - at least one node did not acknowledge in
  time
- `{:error, :failed_generating_configuration}` - the adapter raised
- `{:error, :invalid_cluster_config}` - the adapter did not return a
  `%ExControlPlane.Adapter.ClusterConfig{}`

Use `ExControlPlane.Stream.sync_status/1` to tell "in sync" and "nothing
connected" apart:

```elixir
ExControlPlane.Stream.sync_status("my-cluster")
#=> :in_sync | :out_of_sync | :no_connected_nodes
```

## Telemetry

The ExControlPlane emits various metrics.

### Adapter config callback

```elixir
[:ex_control_plane, :adapter, :generate, :start]
[:ex_control_plane, :adapter, :generate, :stop]
[:ex_control_plane, :adapter, :generate, :exception]
```

### Snapshot read/write

```
[:ex_control_plane, :snapshot, :write, :start]
[:ex_control_plane, :snapshot, :write, :stop]
[:ex_control_plane, :snapshot, :write, :exception]
[:ex_control_plane, :snapshot, :read, :start]
[:ex_control_plane, :snapshot, :read, :stop]
[:ex_control_plane, :snapshot, :read, :exception]

```
