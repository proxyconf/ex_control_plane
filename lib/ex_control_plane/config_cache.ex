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
       streams: %{},
       # monitor ref => caller waiting for a synchronicity result
       waiters: %{}
     }, {:continue, :bootstrap}}
  end

  def handle_continue(:bootstrap, state) do
    load_snapshot()

    generate_config_and_notify_streams(state)

    # if we get this far, let's do an initial snapshot of the
    # potentially changed data.
    create_snapshot()

    {:noreply, state}
  end

  # A snapshot is a best-effort optimisation for a cold start. Whatever is wrong
  # with it, the control plane still has to come up and regenerate from the
  # adapter - crashing here would put the whole application in a restart loop.
  defp load_snapshot do
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
  rescue
    error ->
      Logger.error("Discarding unusable snapshot: #{inspect(error)}")
      :error
  catch
    kind, reason ->
      Logger.error("Discarding unusable snapshot: #{inspect(kind)} #{inspect(reason)}")
      :error
  end

  def handle_call({:load_events, cluster, events, sync_wait_timeout}, from, state) do
    {_, changed_apis} =
      Enum.reject(events, fn {event, _api_id} -> event == :deleted end)
      |> Enum.unzip()

    case state
         |> generate_config(cluster, changed_apis)
         |> cache_notify_resources(cluster) do
      :ok ->
        # Waiting for the nodes to acknowledge must not block this GenServer:
        # config generation for other clusters has to keep making progress while
        # a slow or disconnected dataplane is catching up.
        {_pid, ref} =
          spawn_monitor(fn ->
            GenServer.reply(from, await_synchronicity(cluster, sync_wait_timeout))
          end)

        {:noreply, put_in(state.waiters[ref], from)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(req, _from, state) do
    Logger.error("Unhandled Request #{inspect(req)}")
    {:reply, {:error, :unhandled_request}, state}
  end

  # A waiter that died without replying would leave its caller blocked forever,
  # `load_events/4` waits with `:infinity` by default.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {from, waiters} = Map.pop(state.waiters, ref)

    if from && reason != :normal do
      Logger.error("Synchronicity check crashed: #{inspect(reason)}")
      GenServer.reply(from, {:error, :sync_check_failed})
    end

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(message, state) do
    Logger.debug("Unhandled message #{inspect(message)}")
    {:noreply, state}
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
    kind, reason ->
      Logger.error(
        "Error generating configuration for cluster #{inspect(cluster)}: #{inspect(kind)} #{inspect(reason)}"
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

  defp cache_notify_resources({:error, reason}, _cluster), do: {:error, reason}

  defp cache_notify_resources(_, cluster) do
    Logger.error(
      "Adapter generated invalid configuration for cluster #{inspect(cluster)} (not a %ClusterConfig{})"
    )

    {:error, :invalid_cluster_config}
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

  @doc """
  Checksum over a resource list. Used by both the notification path and
  `ExControlPlane.Stream` to record what a stream has actually been sent.
  """
  def checksum(data) do
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

  # Runs outside the GenServer, so it must always produce a reply - an
  # unanswered caller would block on `load_events/4` forever.
  defp await_synchronicity(cluster, sync_wait_timeout) do
    wait_until_in_sync(cluster, Integer.floor_div(sync_wait_timeout, @sync_wait_step))
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp wait_until_in_sync(_cluster, n) when n <= 0 do
    {:error, :no_sync_state_reached}
  end

  defp wait_until_in_sync(cluster, n) do
    case ExControlPlane.Stream.sync_status(cluster) do
      :out_of_sync ->
        Process.sleep(@sync_wait_step)
        wait_until_in_sync(cluster, n - 1)

      :in_sync ->
        :ok = create_snapshot()
        :ok

      :no_connected_nodes ->
        # Nothing can acknowledge the config. Treated as success so a control
        # plane without a dataplane stays usable, but it is not evidence that
        # the configuration is good.
        Logger.warning(
          cluster: cluster,
          message: "No node connected, configuration was not acknowledged by any node"
        )

        :ok = create_snapshot()
        :ok
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
      case state
           |> generate_config(cluster, api_ids)
           |> cache_notify_resources(cluster) do
        :ok ->
          :ok

        {:error, reason} ->
          # One broken cluster must not stop the remaining clusters from being
          # restored on start-up.
          Logger.error(
            cluster: cluster,
            message: "Bootstrapping configuration failed: #{inspect(reason)}"
          )
      end
    end)
  end
end
