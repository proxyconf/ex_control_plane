defmodule RainbowPlane do
  @moduledoc """
  Documentation for `RainbowPlane`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> RainbowPlane.hello()
      :world

  """
  def hello do
    :world
  end

  def start_n(n_clients, n_servers) do
    RainbowPlane.ColorServers.start_n(n_clients, n_servers)
  end
end
