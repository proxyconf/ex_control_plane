defmodule ExControlPlane.Adapter do
  @moduledoc """
    A behaviour to implement the control plane.
  """

  @type config :: %ExControlPlane.Adapter.ApiConfig{}
  @type cluster_config :: %ExControlPlane.Adapter.ClusterConfig{}

  @callback init() :: state :: any()
  @callback map_reduce(
              state :: any(),
              mapper_fn :: (config :: config(), acc :: any() -> {[any()], acc :: any()}),
              acc :: any()
            ) :: {[any()], acc :: any()}
  @callback get_api_config(state :: any(), cluster_id :: String.t(), api_id :: String.t()) ::
              {:ok, config()} | {:error, reason :: any()}

  @callback generate_resources(state :: any(), cluster_id :: String.t(), changes :: [String.t()]) ::
              cluster_config()

  defmodule ApiConfig do
    defstruct([:api_id, :cluster, :hash, :config])
  end

  defmodule ClusterConfig do
    defstruct(
      secrets: [],
      listeners: [],
      clusters: [],
      route_configurations: [],
      scoped_route_configurations: []
    )
  end
end
