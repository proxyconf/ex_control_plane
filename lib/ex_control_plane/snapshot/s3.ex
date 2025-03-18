defmodule ExControlPlane.Snapshot.S3 do
  @behaviour ExControlPlane.Snapshot.Backend
  use GenServer

  @impl true
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    state = %{
      bucket: Keyword.fetch!(args, :bucket),
      key: Keyword.fetch!(args, :key),
      overrides: Application.get_env(:ex_control_plane, :aws_config_overrides, %{})
    }

    {:ok, state}
  end

  @impl true
  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  @impl true
  def read() do
    GenServer.call(__MODULE__, :read)
  end

  @impl true
  def handle_call(
        {:write, data},
        _from,
        %{bucket: bucket, key: key, overrides: overrides} = state
      ) do
    data = :erlang.term_to_binary(data, [:deterministic])

    res =
      case ExAws.S3.put_object(bucket, key, data)
           |> ExAws.request(overrides) do
        {:ok, %{status_code: 200}} -> :ok
        {:ok, %{status_code: code}} -> {:error, code}
        {:error, reason} -> {:error, reason}
      end

    {:reply, res, state}
  end

  @impl true
  def handle_call(:read, _from, %{bucket: bucket, key: key, overrides: overrides} = state) do
    res =
      case ExAws.S3.get_object(bucket, key)
           |> ExAws.request(overrides) do
        {:ok, %{status_code: 200, body: body}} ->
          body = :erlang.binary_to_term(body)
          {:ok, body}

        {:ok, %{status_code: code}} ->
          {:error, code}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, res, state}
  end
end
