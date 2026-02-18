defmodule ExControlPlane.TestHelpers do
  @moduledoc """
  Shared test helper functions for ExControlPlane tests.
  """

  @doc """
  Waits until the given function returns a truthy value or timeout is reached.

  ## Examples

      wait_until(fn -> Process.alive?(pid) end, 1000)

  Returns the result of the function if truthy, or raises if timeout is reached.
  """
  def wait_until(func, timeout_ms, interval_ms \\ 100)

  def wait_until(_func, timeout_ms, _interval_ms) when timeout_ms <= 0 do
    raise "Timeout waiting for condition"
  end

  def wait_until(func, timeout_ms, interval_ms) do
    case func.() do
      false ->
        Process.sleep(interval_ms)
        wait_until(func, timeout_ms - interval_ms, interval_ms)

      nil ->
        Process.sleep(interval_ms)
        wait_until(func, timeout_ms - interval_ms, interval_ms)

      result ->
        result
    end
  end

  @doc """
  Creates a minimal valid OpenAPI 3.0 spec for testing.
  """
  def minimal_openapi_spec(opts \\ []) do
    servers = Keyword.get(opts, :servers, [%{"url" => "https://api.example.com:443"}])
    paths = Keyword.get(opts, :paths, %{})

    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "Test API",
        "version" => "1.0.0"
      },
      "servers" => servers,
      "paths" => paths
    }
  end

  @doc """
  Creates an OpenAPI path item object for testing.
  """
  def path_item(operations) when is_map(operations) do
    operations
  end

  @doc """
  Creates an OpenAPI operation object for testing.
  """
  def operation(opts \\ []) do
    base = %{
      "responses" => %{
        "200" => %{
          "description" => "Success"
        }
      }
    }

    Enum.reduce(opts, base, fn
      {:parameters, params}, acc -> Map.put(acc, "parameters", params)
      {:request_body, body}, acc -> Map.put(acc, "requestBody", body)
      {:servers, servers}, acc -> Map.put(acc, "servers", servers)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  @doc """
  Starts the application and returns a cleanup function.
  """
  def start_application do
    {:ok, apps} = Application.ensure_all_started(:ex_control_plane)

    fn ->
      Enum.reverse(apps)
      |> Enum.each(fn app ->
        :ok = Application.stop(app)
        :ok = Application.unload(app)
      end)
    end
  end

  @doc """
  Attaches a telemetry handler that sends events to the test process.
  """
  def attach_telemetry_handler(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    fn -> :telemetry.detach(handler_id) end
  end
end
