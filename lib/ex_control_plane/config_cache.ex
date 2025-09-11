defmodule ExControlPlane.ConfigCache do
  @moduledoc """
    This module implements a GenServer handling changes and 
    pushing resource updates to the ExControlPlane.Stream GenServers.
  """
  use GenServer
  require Logger
  alias ExControlPlane.Adapter.ClusterConfig
  alias ExControlPlane.Snapshot.Snapshot

  @cluster "type.googleapis.com/envoy.config.cluster.v3.Cluster"
  @listener "type.googleapis.com/envoy.config.listener.v3.Listener"
  @tls_secret "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
  @route_configuration "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
  @scoped_route_configuration "type.googleapis.com/envoy.config.route.v3.ScopedRouteConfiguration"

  @resources_table :config_cache_tbl_resources
  @resources_candidates_table :config_cache_tbl_resources_candidates
  def start_link(_args) do
    :ets.new(@resources_table, [:public, :named_table])
    :ets.new(@resources_candidates_table, [:public, :named_table])
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def load_events(cluster, events, sync_wait_timeout \\ 5000, timeout \\ :infinity) do
    GenServer.call(
      __MODULE__,
      {:load_events, cluster, events, sync_wait_timeout},
      timeout
    )
  end

  def init(_args) do
    adapter_mod =
      Application.get_env(
        :ex_control_plane,
        :adapter_mod,
        ExControlPlane.SampleEtsAdapter
      )

    {:ok,
     %{
       adapter_mod: adapter_mod,
       adapter_state: adapter_mod.init(),
       streams: %{}
     }, {:continue, :bootstrap}}
  end

  def handle_continue(:bootstrap, state) do
    case Snapshot.get() do
      {:ok, data} ->
        Enum.each(data, fn e ->
          :ets.insert(@resources_table, e)
          :ets.insert(@resources_candidates_table, e)
        end)

        Logger.info("Bootstrapped from snapshot. Notifying resources.")
        notify_resources()

      {:error, reason} ->
        Logger.info("Loading snapshot failed due to #{inspect(reason)}")

        :ok
    end

    generate_config_and_notify_streams(state)

    # if we get this far, let's do an initial snapshot of the
    # potentially changed data.
    create_snapshot()

    {:noreply, state}
  end

  def handle_call({:load_events, cluster, events, sync_wait_timeout}, _from, state) do
    {_, changed_apis} =
      Enum.reject(events, fn {event, _api_id} -> event == :deleted end)
      |> Enum.unzip()

    state
    |> generate_config(cluster, changed_apis)
    |> cache_notify_resources(cluster)

    result =
      Task.async(fn -> wait_for_synchronicity(cluster, sync_wait_timeout) end)
      |> Task.await(:infinity)

    case result do
      :ok ->
        :ok

      {:error, :no_sync_state_reached} ->
        generate_config_and_notify_streams(state)
    end

    {:reply, result, state}
  end

  def handle_call(req, _from, state) do
    Logger.error("Unhandled Request #{inspect(req)}")
    {:reply, {:error, :unhandled_request}, state}
  end

  defp generate_config(state, cluster, changed_apis) do
    start_metadata = %{}

    :telemetry.span(
      [:ex_control_plane, :adapter, :generate],
      start_metadata,
      fn ->
        result =
          state.adapter_mod.generate_resources(
            state.adapter_state,
            cluster,
            changed_apis
          )

        {result, %{count: 1}, %{}}
      end
    )
  rescue
    error ->
      Logger.error(
        "Error generating configuration for cluster #{inspect(cluster)}: #{inspect(error)}"
      )

      {:error, :failed_generating_configuration}
  catch
    error ->
      Logger.error(
        "Error generating configuration for cluster #{inspect(cluster)}: #{inspect(error)}"
      )

      {:error, :failed_generating_configuration}
  end

  defp cache_notify_resources(%ClusterConfig{} = config, cluster) do
    resources =
      %{
        @listener => config.listeners,
        @cluster => config.clusters,
        @route_configuration => config.route_configurations,
        @scoped_route_configuration => config.scoped_route_configurations,
        @tls_secret => config.secrets
      }

    Enum.each(resources, fn {type, resources_for_type} ->
      :ets.insert(
        @resources_candidates_table,
        {{cluster, type}, resources_for_type}
      )
    end)

    Enum.each(resources, fn {type, resources_for_type} ->
      hash = checksum(resources_for_type)

      # not sending the resources to the stream pid, instead let the
      # the stream process fetch the resources if required
      ExControlPlane.Stream.push_resource_changes(cluster, type, hash)
    end)
  end

  defp cache_notify_resources(_, cluster) do
    Logger.error(
      "Adapter generated invalid configuration for cluster #{inspect(cluster)} (not a %ClusterConfig{})"
    )
  end

  defp notify_resources do
    :ets.foldl(
      fn {{cluster, type}, resources}, acc ->
        hash = checksum(resources)
        ExControlPlane.Stream.push_resource_changes(cluster, type, hash)
        acc
      end,
      [],
      @resources_candidates_table
    )
  end

  defp checksum(data) do
    binary = :erlang.term_to_binary(data, [:deterministic])
    :crypto.hash(:md5, binary)
  end

  defp create_snapshot do
    res =
      :ets.foldl(
        fn object, acc ->
          :ets.insert(@resources_table, object)
          [object | acc]
        end,
        [],
        @resources_candidates_table
      )

    Snapshot.put(res)
  end

  def get_resources(cluster, type_url) do
    case {:ets.whereis(@resources_candidates_table),
          :ets.lookup(@resources_candidates_table, {cluster, type_url})} do
      {:undefined, _} -> []
      {_, []} -> []
      {_, [{_, resources}]} -> resources
    end
  end

  def ms2s(milliseconds) do
    seconds = trunc(milliseconds / 1000)
    milliseconds = rem(milliseconds, 1000)
    "#{seconds}.#{milliseconds}s"
  end

  @sync_wait_step 100
  defp wait_for_synchronicity(cluster, sync_wait_timeout) do
    wait_until_in_sync(cluster, Integer.floor_div(sync_wait_timeout, @sync_wait_step))
  end

  defp wait_until_in_sync(_cluster, 0) do
    {:error, :no_sync_state_reached}
  end

  defp wait_until_in_sync(cluster, n) do
    if ExControlPlane.Stream.in_sync(cluster) do
      :ok = create_snapshot()
      :ok
    else
      Process.sleep(@sync_wait_step)
      wait_until_in_sync(cluster, n - 1)
    end
  end

  defp generate_config_and_notify_streams(state) do
    {res, _} =
      state.adapter_mod.map_reduce(
        state.adapter_state,
        fn %ExControlPlane.Adapter.ApiConfig{
             cluster: cluster,
             api_id: api_id
           },
           acc ->
          Logger.info(
            cluster: cluster,
            api_id: api_id,
            message: "API config init from last good state"
          )

          {{cluster, api_id}, acc}
        end,
        # acc
        []
      )

    Enum.group_by(res, fn {cluster, _} -> cluster end, fn {_, api_id} -> api_id end)
    |> Enum.each(fn {cluster, api_ids} ->
      state
      |> generate_config(cluster, api_ids)
      |> cache_notify_resources(cluster)
    end)
  end
end
