defmodule ExControlPlane.Snapshot.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    backend = Application.get_env(:ex_control_plane, :snapshot_backend_mod)
    backend_args = Application.get_env(:ex_control_plane, :snapshot_backend_args, [])

    children =
      if backend do
        [{backend, backend_args}]
      else
        []
      end ++
        [
          {ExControlPlane.Snapshot.Snapshot,
           snapshot_backend_mod: backend,
           persist_interval:
             Application.get_env(:ex_control_plane, :snapshot_persist_interval, 10 * 60 * 1000)}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
