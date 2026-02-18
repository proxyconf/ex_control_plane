defmodule ExControlPlane.EnvoyHelper do
  @moduledoc """
  Helper module for managing Envoy processes in integration tests.

  Provides functions to:
  - Start/stop Envoy processes
  - Wait for Envoy to be ready
  - Query Envoy admin API for verification
  """

  require Logger

  @default_admin_port 19901
  @default_config_path "test/envoy_test.yaml"

  defstruct [:port, :admin_port, :config_path, :log_file]

  @doc """
  Finds the path to the Envoy binary.

  Checks in order:
  1. ENVOY_PATH environment variable
  2. System PATH via `which envoy`
  3. Common Nix store locations
  """
  def envoy_path do
    cond do
      path = System.get_env("ENVOY_PATH") ->
        if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}

      match?({_, 0}, System.cmd("which", ["envoy"], stderr_to_stdout: true)) ->
        {path, 0} = System.cmd("which", ["envoy"], stderr_to_stdout: true)
        {:ok, String.trim(path)}

      true ->
        # Try to find in Nix store
        case System.cmd(
               "sh",
               ["-c", "find /nix/store -name 'envoy' -type f -executable 2>/dev/null | head -1"],
               stderr_to_stdout: true
             ) do
          {path, 0} when path != "" -> {:ok, String.trim(path)}
          _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Starts an Envoy process with the given options.

  ## Options

  - `:config_path` - Path to Envoy config file (default: "test/envoy_test.yaml")
  - `:admin_port` - Admin API port (default: 19901)
  - `:log_level` - Envoy log level (default: "warning")

  Returns `{:ok, %EnvoyHelper{}}` on success.
  """
  def start_envoy(opts \\ []) do
    config_path = Keyword.get(opts, :config_path, @default_config_path)
    admin_port = Keyword.get(opts, :admin_port, @default_admin_port)
    log_level = Keyword.get(opts, :log_level, "warning")

    case envoy_path() do
      {:ok, envoy_bin} ->
        # Create a log file for Envoy output
        log_file = Path.join(System.tmp_dir!(), "envoy_test_#{:rand.uniform(100_000)}.log")

        # Build the command arguments
        args = [
          "-c",
          config_path,
          "-l",
          log_level,
          "--drain-time-s",
          "1",
          "--parent-shutdown-time-s",
          "2"
        ]

        # Start Envoy as a port
        port =
          Port.open({:spawn_executable, envoy_bin}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        envoy = %__MODULE__{
          port: port,
          admin_port: admin_port,
          config_path: config_path,
          log_file: log_file
        }

        {:ok, envoy}

      {:error, reason} ->
        {:error, {:envoy_not_found, reason}}
    end
  end

  @doc """
  Stops an Envoy process.
  """
  def stop_envoy(%__MODULE__{port: port}) when is_port(port) do
    # Get the OS PID of the port
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        # Send SIGTERM to Envoy
        System.cmd("kill", ["-TERM", "#{os_pid}"], stderr_to_stdout: true)

        # Wait a bit for graceful shutdown
        Process.sleep(500)

        # Force kill if still running
        System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)

      nil ->
        :ok
    end

    # Close the port
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  def stop_envoy(_), do: :ok

  @doc """
  Waits for Envoy admin API to be available by polling.
  Note: This does NOT wait for Envoy to be "ready" (which requires xDS config),
  it just waits for the admin API to respond.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 10_000)
  - `:interval` - Polling interval in ms (default: 200)
  """
  def wait_for_envoy(%__MODULE__{admin_port: admin_port}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 200)

    wait_for_admin_api(admin_port, timeout, interval)
  end

  defp wait_for_admin_api(_admin_port, timeout, _interval) when timeout <= 0 do
    {:error, :timeout}
  end

  defp wait_for_admin_api(admin_port, timeout, interval) do
    # We check /server_info instead of /ready because /ready requires
    # Envoy to have received its xDS config, but we want to just know
    # that the admin API is up and accepting connections
    case admin_request(admin_port, "/server_info") do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        Process.sleep(interval)
        wait_for_admin_api(admin_port, timeout - interval, interval)
    end
  end

  @doc """
  Gets the list of clusters from Envoy admin API.
  Returns parsed JSON response.
  """
  def get_clusters(%__MODULE__{admin_port: admin_port}) do
    case admin_request(admin_port, "/clusters?format=json") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the list of listeners from Envoy admin API.
  Returns parsed JSON response.
  """
  def get_listeners(%__MODULE__{admin_port: admin_port}) do
    case admin_request(admin_port, "/listeners?format=json") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the config dump from Envoy admin API.
  This shows all dynamic and static configuration.
  """
  def get_config_dump(%__MODULE__{admin_port: admin_port}) do
    case admin_request(admin_port, "/config_dump") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets server info from Envoy admin API.
  """
  def get_server_info(%__MODULE__{admin_port: admin_port}) do
    case admin_request(admin_port, "/server_info") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if Envoy has received dynamic LDS configuration.
  Returns true if at least one dynamic listener is present.
  """
  def has_dynamic_listeners?(%__MODULE__{} = envoy) do
    case get_config_dump(envoy) do
      {:ok, %{"configs" => configs}} ->
        Enum.any?(configs, fn config ->
          case config do
            %{"@type" => type, "dynamic_listeners" => listeners}
            when is_list(listeners) and length(listeners) > 0 ->
              String.contains?(type, "ListenersConfigDump")

            _ ->
              false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  Checks if Envoy has received dynamic CDS configuration.
  Returns true if at least one dynamic cluster is present.
  """
  def has_dynamic_clusters?(%__MODULE__{} = envoy) do
    case get_config_dump(envoy) do
      {:ok, %{"configs" => configs}} ->
        Enum.any?(configs, fn config ->
          case config do
            %{"@type" => type, "dynamic_active_clusters" => clusters}
            when is_list(clusters) and length(clusters) > 0 ->
              String.contains?(type, "ClustersConfigDump")

            _ ->
              false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  Gets the names of dynamic listeners from Envoy.
  """
  def get_dynamic_listener_names(%__MODULE__{} = envoy) do
    case get_config_dump(envoy) do
      {:ok, %{"configs" => configs}} ->
        configs
        |> Enum.flat_map(fn config ->
          case config do
            %{"@type" => type, "dynamic_listeners" => listeners} ->
              if String.contains?(type, "ListenersConfigDump") do
                Enum.map(listeners, fn l ->
                  get_in(l, ["active_state", "listener", "name"]) ||
                    get_in(l, ["name"])
                end)
              else
                []
              end

            _ ->
              []
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  @doc """
  Gets the names of dynamic clusters from Envoy.
  """
  def get_dynamic_cluster_names(%__MODULE__{} = envoy) do
    case get_config_dump(envoy) do
      {:ok, %{"configs" => configs}} ->
        configs
        |> Enum.flat_map(fn config ->
          case config do
            %{"@type" => type, "dynamic_active_clusters" => clusters} ->
              if String.contains?(type, "ClustersConfigDump") do
                Enum.map(clusters, fn c ->
                  get_in(c, ["cluster", "name"])
                end)
              else
                []
              end

            _ ->
              []
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # Makes an HTTP request to the Envoy admin API
  defp admin_request(admin_port, path) do
    url = "http://127.0.0.1:#{admin_port}#{path}"

    request = Finch.build(:get, url)

    case Finch.request(request, ExControlPlane.TestFinch) do
      {:ok, response} ->
        {:ok, %{status: response.status, body: response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
