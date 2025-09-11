defmodule ExControlPlane.Stream do
  @moduledoc """
    This module implements a GenServer that is used to communicate
    with the GRPC stream. For Envoy XDS/ADS one GRPC stream per resource
    type is used. This enables that discovery request/responses for a 
    specific resource type can be easily dispatched via the GenServers.
    To simplify the dispatching an Elixir Registry is use. 

    The GenServer monitors the GRPC stream process and terminates if the
    GRPC stream stops, e.g. due to a disconnect of an Envoy node.
  """
  use GenServer
  require Logger
  alias ExControlPlane.ConfigCache

  def ensure_registred(grpc_stream, node_info, type_url) do
    with [] <-
           Registry.lookup(
             ExControlPlane.StreamRegistry,
             {grpc_stream, node_info.cluster, type_url}
           ),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             ExControlPlane.StreamSupervisor,
             %{
               id: ExControlPlane.Stream,
               start: {__MODULE__, :start_link, [[grpc_stream, node_info, type_url]]},
               restart: :transient
             }
           ) do
      {:ok, pid}
    else
      [{pid, _value}] ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  def push_resource_changes(cluster_id, type_url, hash) do
    Registry.select(ExControlPlane.StreamRegistry, [
      {{{:_, :"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", cluster_id}, {:==, :"$2", type_url}],
       [:"$3"]}
    ])
    |> Enum.each(fn pid ->
      GenServer.call(pid, {:push_resource_changes, hash})
    end)
  end

  def in_sync(cluster_id) do
    num_unsynchronized_streams =
      Registry.count_select(ExControlPlane.StreamRegistry, [
        {{{:_, :"$1", :_}, :_, %{in_sync: :"$2"}},
         [{:==, :"$1", cluster_id}, {:==, :"$2", false}], [true]}
      ])

    num_unsynchronized_streams == 0
  end

  def event(grpc_stream, node_info, type_url, {version, error}) do
    {:ok, pid} = ensure_registred(grpc_stream, node_info, type_url)

    GenServer.call(
      pid,
      {:event, version, error}
    )
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
           version: nil,
           hash: nil,
           waiting_ack: nil
         }}

      {:error, {:already_registered, _pid} = error} ->
        Logger.warning(
          cluster: node_info.cluster,
          message: "GRPC stream for type #{type_url} already registered."
        )

        {:stop, error}
    end
  end

  def handle_call({:event, version, error}, _from, %{waiting_ack: waiting_ack} = state) do
    node_info = state.node_info

    case state.version do
      ^version when is_nil(error) ->
        # nothing to do
        Logger.info(
          cluster: node_info.cluster,
          message: "#{state.type_url} Acked version by #{node_info.node_id} version #{version}"
        )

        update_status(%{in_sync: true})
        {:reply, :ok, %{state | waiting_ack: nil}}

      nil when is_nil(error) ->
        # new node
        {:reply, :ok, push_resources(%{state | version: 0})}

      _ when is_nil(error) and waiting_ack != nil and waiting_ack > version ->
        # if many updates are in flight, keep the waiting ack (TBH, not sure if this can happen)
        Logger.info(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Acked older version by #{node_info.node_id} version #{version}, current version is #{state.version}."
        )

        update_status(%{in_sync: false})

        # keep state
        {:reply, :ok, state}

      _ when not is_nil(error) ->
        # NACK
        Logger.warning(
          cluster: node_info.cluster,
          message:
            "#{state.type_url} Error rolling out version #{version} by #{node_info.node_id}, current version is #{state.version}. Error is #{inspect(error)}"
        )

        update_status(%{in_sync: false})

        # keep state
        {:reply, :ok, state}
    end
  end

  def handle_call({:push_resource_changes, hash}, _from, state) do
    if state.hash != hash do
      Logger.info(cluster: state.node_info.cluster, message: "changes for type #{state.type_url}")
      {:reply, :ok, push_resources(%{state | hash: hash})}
    else
      Logger.info(
        cluster: state.node_info.cluster,
        message: "No changes for type #{state.type_url}"
      )

      {:reply, :ok, state}
    end
  end

  def handle_info({:DOWN, _mref, :process, _pid, reason}, state) do
    Logger.info(
      cluster: state.node_info.cluster,
      message: "GRPC stream for type #{state.type_url} terminated due to #{inspect(reason)}"
    )

    {:stop, :normal, state}
  end

  defp monitor_grpc_stream_pid(pid) do
    Process.monitor(pid)
  end

  defp push_resources(state) do
    resources =
      ConfigCache.get_resources(state.node_info.cluster, state.type_url)

    case resources do
      [] when state.version == 0 ->
        Logger.info(
          cluster: state.node_info.cluster,
          message:
            "No initial #{state.type_url} resources for #{state.node_info.node_id} exist, wait for update"
        )

        state

      _ ->
        new_version = state.version + 1

        {:ok, response} =
          Protobuf.JSON.from_decoded(
            %{
              "version_info" => "#{new_version}",
              "type_url" => state.type_url,
              "control_plane" => %{
                "identifier" => "#{node()}"
              },
              "resources" =>
                Enum.map(resources, fn r -> %{"@type" => state.type_url, "value" => r} end),
              "nonce" => nonce()
            },
            Envoy.Service.Discovery.V3.DiscoveryResponse
          )

        GRPC.Server.Stream.send_reply(state.stream, response, [])

        Logger.info(
          cluster: state.node_info.cluster,
          message:
            "#{state.type_url} Push new version #{new_version} to #{state.node_info.node_id}"
        )

        update_status(%{in_sync: false})

        %{state | version: new_version, waiting_ack: new_version}
    end
  end

  defp nonce do
    "#{node()}#{DateTime.utc_now() |> DateTime.to_unix(:nanosecond)}" |> Base.encode64()
  end

  defp update_status(status_map) when is_map(status_map) do
    [key] = Registry.keys(ExControlPlane.StreamRegistry, self())

    Registry.update_value(ExControlPlane.StreamRegistry, key, fn status ->
      Map.merge(status, status_map)
    end)
  end
end
