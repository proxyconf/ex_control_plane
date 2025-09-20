defmodule RainbowPlane.ControlPlane do
  @behaviour ExControlPlane.Adapter
  alias ExControlPlane.Adapter.ApiConfig
  alias ExControlPlane.Adapter.ClusterConfig

  # cluster_name must be aligned with cluster name found in Envoy Bootstrap config
  @cluster_name "rainbow"
  @api_id "rainbow"

  def configure_deployment(config) do
    :ets.insert(
      __MODULE__,
      {{@cluster_name, @api_id},
       %ApiConfig{
         api_id: @api_id,
         cluster: @cluster_name,
         hash: :crypto.strong_rand_bytes(10),
         config: config
       }}
    )

    ExControlPlane.ConfigCache.load_events(@cluster_name, [{:updated, @api_id}])
  end

  @impl true
  @spec init() :: :ets.table()
  def init do
    # our control plane uses an ETS table as it's main state store
    :ets.new(__MODULE__, [:named_table, :public])
  end

  @impl true
  def generate_resources(tid, _cluster_name, _updated) do
    case :ets.lookup(tid, {@cluster_name, @api_id}) do
      [] ->
        %ClusterConfig{}

      [{_, %ApiConfig{config: %ClusterConfig{} = config}}] ->
        config
    end
  end

  @impl true
  def map_reduce(tid, mapper_fn, acc) do
    :ets.foldl(
      fn {_, config}, {results, acc} ->
        {map_res, acc} = mapper_fn.(config, acc)
        {[map_res | results], acc}
      end,
      {[], acc},
      tid
    )
  end
end
