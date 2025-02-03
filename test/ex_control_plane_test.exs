defmodule ExControlPlaneTest do
  use ExUnit.Case
  doctest ExControlPlane

  test "greets the world" do
    assert ExControlPlane.hello() == :world
  end
end
