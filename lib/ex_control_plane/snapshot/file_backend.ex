defmodule ExControlPlane.Snapshot.FileBackend do
  @behaviour ExControlPlane.Snapshot.Backend
  use GenServer

  @impl true
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    state = %{filename: Keyword.fetch!(args, :filename)}

    {:ok, state}
  end

  @impl true
  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  @impl true
  def read do
    GenServer.call(__MODULE__, :read)
  end

  @impl true
  def handle_call(
        {:write, data},
        _from,
        %{filename: filename} = state
      ) do
    data = :erlang.term_to_binary(data, [:deterministic])
    res = File.write(filename, data)

    {:reply, res, state}
  end

  @impl true
  def handle_call(:read, _from, %{filename: filename} = state) do
    case File.read(filename) do
      {:ok, data} ->
        {:reply, {:ok, :erlang.binary_to_term(data)}, state}

      {:error, :enoent} ->
        {:reply, {:error, :no_snapshot_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
