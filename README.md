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
