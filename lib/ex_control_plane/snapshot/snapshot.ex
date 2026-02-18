defmodule ExControlPlane.Snapshot.Snapshot do
  @moduledoc """
  Manages snapshots which can be used to bootstrap ExControlPlane in a cold start situation.
  """

  use GenServer
  require Logger

  @snapshot_tbl :snapshot_tbl
  @snapshot_key :snapshot_key
  @snapshot_version 1

  defstruct backend_mod: nil, checksum: nil, persist_interval: nil

  alias ExControlPlane.Snapshot.Snapshot

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def put(data) do
    :ets.insert(@snapshot_tbl, {@snapshot_key, data})
    :ok
  end

  def get() do
    # since this call will come after attempting to read the snapshot
    # in :read (handle_continue) directly after init - it will always
    # return snapshot data if any are available to be read.
    GenServer.call(__MODULE__, :get, :infinity)
  end

  # made public with @doc false for testing
  @doc false
  def force_persist do
    GenServer.call(__MODULE__, :force_persist)
  end

  @impl true
  def init(args) do
    :ets.new(@snapshot_tbl, [:public, :named_table])

    persist_interval =
      Keyword.get(args, :persist_interval, 10 * 60 * 1000)

    backend_mod = Keyword.get(args, :snapshot_backend_mod)

    if backend_mod do
      {:ok, %Snapshot{backend_mod: backend_mod, persist_interval: persist_interval},
       {:continue, :read}}
    else
      Logger.info("No snapshot backend configured. Snapshots are disabled.")
      {:ok, :no_snapshot_config}
    end
  end

  @impl true
  def handle_continue(
        :read,
        %Snapshot{backend_mod: backend_mod, persist_interval: interval} = state
      ) do
    with {:ok, data} <- read_snapshot(backend_mod),
         :ok <- check_version(data),
         {:ok, checksum} <- verify_checksum(data),
         %{data: data} <- data do
      Logger.info("Snapshot read")
      :ets.insert(@snapshot_tbl, {@snapshot_key, data})

      _ = persist_after(interval)

      {:noreply, %Snapshot{state | checksum: checksum}}
    else
      {:error, :no_snapshot_found} ->
        Logger.warning("No snapshot found")
        _ = persist_after(interval)
        {:noreply, state}

      {:error, error} ->
        _ = persist_after(interval)
        failed_reading_snapshot(state, error)

      error ->
        _ = persist_after(interval)
        failed_reading_snapshot(state, error)
    end
  end

  defp check_version(%{version: version}) do
    if version == @snapshot_version do
      :ok
    else
      {:error, "version_mismatch, got (#{version}), expected (#{@snapshot_version})"}
    end
  end

  defp check_version(_), do: "no version information found"

  defp verify_checksum(%{data: data, checksum: checksum}) do
    case checksum(data) do
      ^checksum -> {:ok, checksum}
      _ -> {:error, :checksum}
    end
  end

  @impl true
  def handle_call(_, _from, :snapshots_disabled) do
    {:ok, {:error, :snapshots_disabled}, :snapshots_disabled}
  end

  def handle_call(:get, _from, state) do
    res =
      case :ets.lookup(@snapshot_tbl, @snapshot_key) do
        [] -> {:error, :no_snapshot}
        [{@snapshot_key, data}] -> {:ok, data}
      end

    {:reply, res, state}
  end

  def handle_call(:force_persist, _from, %Snapshot{} = state) do
    checksum = maybe_persist(state)
    {:reply, :ok, %Snapshot{state | checksum: checksum}}
  end

  @impl true
  def handle_info(:persist, %Snapshot{persist_interval: interval} = state) do
    checksum = maybe_persist(state)
    _ = persist_after(interval)
    {:noreply, %Snapshot{state | checksum: checksum}}
  end

  defp maybe_persist(%Snapshot{checksum: old_checksum, backend_mod: backend_mod}) do
    Logger.debug("Checking snapshot for changes")
    # persist snapshot if checksum differs
    case :ets.lookup(@snapshot_tbl, @snapshot_key) do
      [{@snapshot_key, data}] ->
        checksum = checksum(data)

        if checksum != old_checksum do
          data = %{data: data, checksum: checksum, version: @snapshot_version}

          case write_snapshot(data, backend_mod) do
            :ok ->
              Logger.info("Snapshot persisted")
              checksum

            {:error, error} ->
              Logger.warning("Writing snapshot failed due to: #{inspect(error)}")
              old_checksum
          end
        else
          Logger.debug("Snapshot unchanged")
          old_checksum
        end

      _ ->
        old_checksum
    end
  end

  defp read_snapshot(backend_mod) do
    start_metadata = %{}

    :telemetry.span(
      [:ex_control_plane, :snapshot, :read],
      start_metadata,
      fn ->
        result = backend_mod.read()
        {result, %{count: 1}, %{}}
      end
    )
  rescue
    error ->
      {:error, error}
  catch
    error ->
      {:error, error}

    :exit, error ->
      {:error, error}
  end

  defp write_snapshot(data, backend_mod) do
    start_metadata = %{}

    :telemetry.span(
      [:ex_control_plane, :snapshot, :write],
      start_metadata,
      fn ->
        result = backend_mod.write(data)
        {result, %{count: 1}, %{}}
      end
    )
  rescue
    error ->
      {:error, error}
  catch
    error ->
      {:error, error}

    :exit, error ->
      {:error, error}
  end

  defp persist_after(interval) do
    Process.send_after(self(), :persist, interval)
  end

  defp checksum(data) do
    data = :erlang.term_to_binary(data)
    :crypto.hash(:sha256, data)
  end

  defp failed_reading_snapshot(state, error) do
    Logger.warning("Reading snapshot failed due to: #{inspect(error)}")
    {:noreply, state}
  end
end
