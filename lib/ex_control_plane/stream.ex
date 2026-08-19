defmodule ExControlPlane.Stream do
  @moduledoc """
    This module implements a GenServer that is used to communicate
    with the GRPC stream. With ADS a node multiplexes every resource type
    over a *single* GRPC stream, so one GenServer per resource type is
    registered for that stream. This enables that discovery
    request/responses for a specific resource type can be easily dispatched
    via the GenServers. To simplify the dispatching an Elixir Registry is use.

    The GenServer monitors the GRPC stream process and terminates if the
    GRPC stream stops, e.g. due to a disconnect of an Envoy node. Because all
    GenServers of a node share that process, a node disconnect takes all of
    its streams down together.

    ## ACK/NACK bookkeeping

    A `DiscoveryRequest` is classified by its `response_nonce`, never by its
    `version_info`:

      * empty nonce - initial request of a newly connected *or reconnected*
        stream. `version_info` then carries whatever version the node last
        applied, which for a reconnect was handed out by a *previous* control
        plane instance and is meaningless to us.
      * nonce of our latest response - ACK (no `error_detail`) or NACK.
      * any other nonce - ACK/NACK of a response we have already superseded.

    `version_info` is opaque to the node (xDS protocol), so this control plane
    never parses or compares the version reported by the node.
  """
  use GenServer
  require Logger
  alias ExControlPlane.ConfigCache

  # A Stream is bound to the lifetime of its GRPC stream: if it dies, the GRPC
  # stream handler is gone too and the node has to reconnect. Restarting it would
  # only re-register a GenServer for a connection that no longer exists, while
  # putting crash storms on the supervisor's restart budget.
  @child_restart :temporary

  # A push writes to the GRPC stream, which can block on HTTP/2 flow control when
  # a node is slow to read. Bound it so one stuck node cannot stall the caller.
  @default_push_timeout 10_000

  def ensure_registred(grpc_stream, node_info, type_url) do
    case Registry.lookup(
           ExControlPlane.StreamRegistry,
           {grpc_stream, node_info.cluster, type_url}
         ) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        start_stream(grpc_stream, node_info, type_url)
    end
  end

  defp start_stream(grpc_stream, node_info, type_url) do
    DynamicSupervisor.start_child(
      ExControlPlane.StreamSupervisor,
      %{
        id: ExControlPlane.Stream,
        start: {__MODULE__, :start_link, [[grpc_stream, node_info, type_url]]},
        restart: @child_restart
      }
    )
    |> case do
      {:ok, pid} ->
        {:ok, pid}

      # Lost the race against a concurrent registration for the same key.
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:already_registered, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          cluster: node_info.cluster,
          message: "Cannot start stream for type #{type_url}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Notifies every stream of `cluster_id` serving `type_url` about a resource
  change.

  Streams are notified concurrently and independently: a stream that died,
  crashed, or is too slow to accept the push is logged and skipped rather than
  failing the caller. Such a stream stays out of sync, which surfaces through
  `sync_status/1`.
  """
  def push_resource_changes(cluster_id, type_url, hash) do
    streams_of(cluster_id, type_url)
    |> Task.async_stream(
      fn pid -> notify_stream(pid, hash, cluster_id, type_url) end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn _ -> :ok end)
  end

  defp notify_stream(pid, hash, cluster_id, type_url) do
    GenServer.call(pid, {:push_resource_changes, hash}, push_timeout())
  catch
    kind, reason ->
      Logger.error(
        cluster: cluster_id,
        message:
          "Pushing #{type_url} to stream #{inspect(pid)} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      :error
  end

  defp push_timeout do
    Application.get_env(:ex_control_plane, :stream_push_timeout, @default_push_timeout)
  end

  defp streams_of(cluster_id, type_url) do
    Registry.select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", cluster_id}, {:==, :"$2", type_url}],
       [:"$3"]}
    ])
  end

  @doc """
  Whether every stream of `cluster_id` has acknowledged the resources it was
  last sent.

  Note that this is also true when no node is connected at all - use
  `sync_status/1` to tell the two apart.
  """
  def in_sync(cluster_id) do
    sync_status(cluster_id) != :out_of_sync
  end

  @doc """
  Synchronisation state of `cluster_id`:

    * `:in_sync` - every registered stream acknowledged its latest resources
    * `:out_of_sync` - at least one stream has not acknowledged (yet)
    * `:no_connected_nodes` - no node is connected for this cluster, so there is
      nothing that could acknowledge
  """
  def sync_status(cluster_id) do
    cond do
      count_unsynchronized_streams(cluster_id) > 0 -> :out_of_sync
      count_streams(cluster_id) == 0 -> :no_connected_nodes
      true -> :in_sync
    end
  end

  defp count_unsynchronized_streams(cluster_id) do
    Registry.count_select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :_}, :_, %{in_sync: :"$2"}}, [{:==, :"$1", cluster_id}, {:==, :"$2", false}],
       [true]}
    ])
  end

  defp count_streams(cluster_id) do
    Registry.count_select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :_}, :_, :_}, [{:==, :"$1", cluster_id}], [true]}
    ])
  end

  @doc """
  Dispatches a discovery request to the stream responsible for `type_url`.

  Never raises: the caller is the GRPC stream handler, so letting an error escape
  here would tear down the node's whole ADS session.
  """
  def event(grpc_stream, node_info, type_url, %{} = request) do
    with {:ok, pid} <- ensure_registred(grpc_stream, node_info, type_url) do
      GenServer.call(pid, {:event, request}, push_timeout())
    end
  catch
    kind, reason ->
      Logger.error(
        cluster: node_info.cluster,
        message:
          "Handling #{type_url} discovery request of #{node_info.node_id} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      {:error, reason}
  end

  def start_link([grpc_stream, node_info, type_url]) do
    GenServer.start_link(__MODULE__, [grpc_stream, node_info, type_url])
  end

  def init([grpc_stream, node_info, type_url]) do
    case Registry.register(
           ExControlPlane.StreamRegistry,
           {grpc_stream, node_info.cluster, type_url},
           %{in_sync: false}
         ) do
      {:ok, _pid} ->
        Logger.info(
          cluster: node_info.cluster,
          message: "GRPC stream for type #{type_url} registered."
        )

        monitor_grpc_stream_pid(grpc_stream.payload.pid)

        {:ok,
         %{
           stream: grpc_stream,
           type_url: type_url,
           node_info: node_info,
           version: 0,
           nonce: nil,
           hash: nil
         }}

      {:error, {:already_registered, _pid} = error} ->
        Logger.warning(
          cluster: node_info.cluster,
          message: "GRPC stream for type #{type_url} already registered."
        )

        {:stop, error}
    end
  end

  def handle_call(
        {:event, %{version_info: reported_version, nonce: nonce, error: error}},
        _from,
        state
      ) do
    node_info = state.node_info

    cond do
      nonce in [nil, ""] ->
        # Initial request of a new or *reconnected* stream. A reconnecting node
        # reports the version it last applied from a previous control plane
        # instance - opaque to us, so we answer with the full state of the world.
        Logger.info(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Initial request by #{node_info.node_id}, reported version #{inspect(reported_version)}"
        )

        {:reply, :ok, push_resources(state)}

      nonce != state.nonce ->
        # ACK/NACK for a response that a newer push already superseded.
        Logger.info(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Stale #{ack_or_nack(error)} by #{node_info.node_id} for nonce #{inspect(nonce)}, current version is #{state.version}"
        )

        {:reply, :ok, state}

      is_nil(error) ->
        Logger.info(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Acked version by #{node_info.node_id} version #{state.version}"
        )

        update_status(%{in_sync: true})
        {:reply, :ok, state}

      true ->
        Logger.warning(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Error rolling out version #{state.version} by #{node_info.node_id}. Error is #{inspect(error)}"
        )

        update_status(%{in_sync: false})
        {:reply, :ok, state}
    end
  end

  def handle_call({:push_resource_changes, hash}, _from, state) do
    if state.hash != hash do
      Logger.info(cluster: state.node_info.cluster, message: "changes for type #{state.type_url}")

      # Mark the stream out of sync *before* replying, so a caller that starts
      # polling `sync_status/1` right after cannot observe the previous
      # acknowledgement and mistake it for this update being applied. The write
      # to the GRPC stream itself happens in the continue, off the caller's
      # critical path: it can block on HTTP/2 flow control and must not stall
      # config distribution to other nodes.
      update_status(%{in_sync: false})
      {:reply, :ok, state, {:continue, :push_resources}}
    else
      Logger.info(
        cluster: state.node_info.cluster,
        message: "No changes for type #{state.type_url}"
      )

      {:reply, :ok, state}
    end
  end

  def handle_call(request, _from, state) do
    Logger.error(
      cluster: state.node_info.cluster,
      message: "Unhandled request #{inspect(request)} for type #{state.type_url}"
    )

    {:reply, {:error, :unhandled_request}, state}
  end

  def handle_continue(:push_resources, state) do
    {:noreply, push_resources(state)}
  end

  def handle_info({:DOWN, _mref, :process, _pid, reason}, state) do
    Logger.info(
      cluster: state.node_info.cluster,
      message: "GRPC stream for type #{state.type_url} terminated due to #{inspect(reason)}"
    )

    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    Logger.debug(
      cluster: state.node_info.cluster,
      message: "Unhandled message #{inspect(message)} for type #{state.type_url}"
    )

    {:noreply, state}
  end

  defp ack_or_nack(nil), do: "ack"
  defp ack_or_nack(_error), do: "nack"

  defp monitor_grpc_stream_pid(pid) do
    Process.monitor(pid)
  end

  defp push_resources(state) do
    resources =
      ConfigCache.get_resources(state.node_info.cluster, state.type_url)

    case resources do
      [] when state.version == 0 ->
        # Never answer the initial request with an empty response: a reconnecting
        # node would drop the resources it is currently serving traffic with.
        # The hash is deliberately not recorded so the next notification retries.
        Logger.info(
          cluster: state.node_info.cluster,
          message:
            "No initial #{state.type_url} resources for #{state.node_info.node_id} exist, wait for update"
        )

        state

      _ ->
        new_version = state.version + 1
        nonce = nonce()

        case send_discovery_response(state, resources, new_version, nonce) do
          :ok ->
            Logger.info(
              cluster: state.node_info.cluster,
              message:
                "#{state.type_url} Push new version #{new_version} to #{state.node_info.node_id}"
            )

            update_status(%{in_sync: false})

            %{state | version: new_version, nonce: nonce, hash: ConfigCache.checksum(resources)}

          {:error, reason} ->
            # Neither the version nor the hash advance, so the next notification
            # retries. The stream stays out of sync, which surfaces via
            # `sync_status/1` instead of taking the process down.
            Logger.error(
              cluster: state.node_info.cluster,
              message:
                "#{state.type_url} Pushing version #{new_version} to #{state.node_info.node_id} failed: #{inspect(reason)}"
            )

            update_status(%{in_sync: false})

            state
        end
    end
  end

  defp send_discovery_response(state, resources, version, nonce) do
    with {:ok, response} <-
           Protobuf.JSON.from_decoded(
             %{
               "version_info" => "#{version}",
               "type_url" => state.type_url,
               "control_plane" => %{
                 "identifier" => "#{node()}"
               },
               "resources" =>
                 Enum.map(resources, fn r -> %{"@type" => state.type_url, "value" => r} end),
               "nonce" => nonce
             },
             Envoy.Service.Discovery.V3.DiscoveryResponse
           ) do
      GRPC.Server.Stream.send_reply(state.stream, response, [])
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp nonce do
    "#{node()}#{DateTime.utc_now() |> DateTime.to_unix(:nanosecond)}" |> Base.encode64()
  end

  defp update_status(status_map) when is_map(status_map) do
    case Registry.keys(ExControlPlane.StreamRegistry, self()) do
      [key] ->
        Registry.update_value(ExControlPlane.StreamRegistry, key, fn status ->
          Map.merge(status, status_map)
        end)

      keys ->
        # Cannot happen for a registered stream, but a status update must never
        # be the reason a stream dies.
        Logger.error("Cannot update stream status, unexpected registry keys #{inspect(keys)}")
        :error
    end
  end
end
