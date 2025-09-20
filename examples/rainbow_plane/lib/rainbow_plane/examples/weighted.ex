defmodule RainbowPlane.Examples.Weighted do
  alias ExControlPlane.Adapter.ClusterConfig
  alias RainbowPlane.Examples.Cluster
  alias RainbowPlane.Examples.Listener
  alias RainbowPlane.Examples.RouteConfiguration
  alias RainbowPlane.Helpers

  def setup(n_colors) do
    Task.async(fn ->
      1..100
      |> Enum.each(fn _ ->
        main_color =
          0..(n_colors - 1)
          |> Enum.random()

        %ClusterConfig{
          listeners: [Listener.default(8080)],
          route_configurations: [RouteConfiguration.default()],
          clusters:
            Cluster.from_color_servers() |> enable_weighted_balancing(main_color, n_colors)
        }
        |> RainbowPlane.ControlPlane.configure_deployment()

        Process.sleep(10_000)
      end)
    end)
  end

  defp enable_weighted_balancing(clusters_config, main_color, n_colors) do
    weights(main_color, n_colors)
    |> Enum.reduce(clusters_config, fn {i, weight}, clusters_config_acc ->
      Helpers.patch(
        clusters_config_acc,
        :insert,
        [0, "load_assignment", "endpoints", 0, "lb_endpoints", i, "load_balancing_weight"],
        weight
      )
    end)
  end

  def weights(main_color, n_colors, min_weight \\ 1, max_weight \\ 1000) do
    colors = 0..(n_colors - 1)
    n = n_colors
    mu = main_color
    sigma = sigma()

    # Raw weights using normal distribution formula
    raw =
      for i <- 0..(n - 1) do
        :math.exp(-:math.pow(i - mu, 2) / (2 * :math.pow(sigma, 2)))
      end

    max_r = Enum.max(raw)
    min_r = Enum.min(raw)

    scaled =
      Enum.map(raw, fn r ->
        round(min_weight + (r - min_r) / (max_r - min_r) * (max_weight - min_weight))
      end)

    Enum.zip(colors, scaled)
  end

  def sigma do
    # small sigma = narrow curve
    # sigma of 0.1 with 100 colors works quite well (all clients served by same color server)
    # sigma of 0.3 with 100 colors works very well, as most client see the same color, and still some flickering
    0.5
  end
end
