defmodule ExControlPlane.Snapshot.Backend do
  @moduledoc """
  A behaviour module for snapshot backends. Implementations must be
  atomic/transactional since in a multi-replica setting using the same
  target, the backend may be called concurrently. 
  """

  @callback start_link(args :: term()) :: {:ok, pid()} | {:error, term()}
  @callback write(term()) :: :ok | {:error, term()}
  @callback read() :: {:ok, term()} | {:error, term()}
end
